/**
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.hadoop.mapreduce.lib.join;

import java.io.IOException;
import java.util.ArrayList;
import java.util.PriorityQueue;

import org.apache.hadoop.classification.InterfaceAudience;
import org.apache.hadoop.classification.InterfaceStability;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.io.NullWritable;
import org.apache.hadoop.io.Writable;
import org.apache.hadoop.io.WritableComparable;
import org.apache.hadoop.io.WritableComparator;
import org.apache.hadoop.util.ReflectionUtils;

/**
 * Prefer the &quot;rightmost&quot; data source for this key.
 * For example, <code>override(S1,S2,S3)</code> will prefer values
 * from S3 over S2, and values from S2 over S1 for all keys
 * emitted from all sources.
 */
@InterfaceAudience.Public
@InterfaceStability.Stable
public class OverrideRecordReader<K extends WritableComparable<?>,
                                  V extends Writable>
    extends MultiFilterRecordReader<K,V> {

  OverrideRecordReader(int id, Configuration conf, int capacity,
      Class<? extends WritableComparator> cmpcl) throws IOException {
    super(id, conf, capacity, cmpcl);
  }
  private Class<? extends Writable> valueclass = null;

  /**
   * Emit the value with the highest position in the tuple.
   */
  @SuppressWarnings("unchecked") // No static typeinfo on Tuples
  protected V emit(TupleWritable dst) {
    return (V) dst.iterator().next();
  }

  @SuppressWarnings("unchecked") // Explicit check for value class agreement
  public V createValue() {
    if (null == valueclass) {
      Class<?> cls = kids[kids.length -1].createValue().getClass();
      for (int i = kids.length -1; cls.equals(NullWritable.class); i--) {
        cls = kids[i].createValue().getClass();
      }
      valueclass = cls.asSubclass(Writable.class);
    }
    if (valueclass.equals(NullWritable.class)) {
      return (V) NullWritable.get();
    }
    return (V) ReflectionUtils.newInstance(valueclass, null);
  }

  /**
   * Instead of filling the JoinCollector with iterators from all
   * data sources, fill only the rightmost for this key.
   * This not only saves space by discarding the other sources, but
   * it also emits the number of key-value pairs in the preferred
   * RecordReader instead of repeating that stream n times, where
   * n is the cardinality of the cross product of the discarded
   * streams for the given key.
   */
  protected void fillJoinCollector(K iterkey) 
      throws IOException, InterruptedException {
    final PriorityQueue<ComposableRecordReader<K,?>> q = 
      getRecordReaderQueue();
    if (q != null && !q.isEmpty()) {
      int highpos = -1;
      ArrayList<ComposableRecordReader<K,?>> list =
        new ArrayList<ComposableRecordReader<K,?>>(kids.length);
      q.peek().key(iterkey);
      final WritableComparator cmp = getComparator();
      while (0 == cmp.compare(q.peek().key(), iterkey)) {
        ComposableRecordReader<K,?> t = q.poll();
        if (-1 == highpos || list.get(highpos).id() < t.id()) {
          highpos = list.size();
        }
        list.add(t);
        if (q.isEmpty())
          break;
      }
      ComposableRecordReader<K,?> t = list.remove(highpos);
      t.accept(jc, iterkey);
      for (ComposableRecordReader<K,?> rr : list) {
        rr.skip(iterkey);
      }
      list.add(t);
      for (ComposableRecordReader<K,?> rr : list) {
        if (rr.hasNext()) {
          q.add(rr);
        }
      }
    }
  }

}
