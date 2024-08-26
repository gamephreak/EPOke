import assert from 'assert';

import {GenerationNum, StatsTable} from '@pkmn/types';

import * as data from '../data';
import {Spread} from '../spread';
import {Stats} from '../stats';

class Random {
  seed: number;

  constructor(seed = 0x27d4eb2d) {
    this.seed = seed;
  }

  // Mulberry32: https://gist.github.com/tommyettinger/46a874533244883189143505d203312c
  next(min?: number, max?: number) {
    if (min) min = Math.floor(min);
    if (max) max = Math.floor(max);

    let z = (this.seed += 0x6d2b79f5 | 0);
    z = Math.imul(z ^ (z >>> 15), z | 1);
    z = z ^ (z + Math.imul(z ^ (z >>> 7), z | 61));
    z = (z ^ (z >>> 14)) >>> 0;
    const n = z / 2 ** 32;

    if (min === undefined) return n;
    if (!max) return Math.floor(n * min);
    return Math.floor(n * (max - min)) + min;
  }

  sample<T>(arr: T[], remove = false) {
    if (arr.length === 0) throw new RangeError('Cannot sample an empty array');
    const index = this.next(arr.length);
    const val = arr[index];
    if (remove) {
      arr[index] = arr[arr.length - 1];
      arr.pop();
    }
    if (val === undefined && !Object.prototype.hasOwnProperty.call(arr, index)) {
      throw new RangeError('Cannot sample a sparse array');
    }
    return val;
  }
}

export function run(N: number, initial?: number) {
  const random = new Random(initial);
  for (let i = 0; i < N; i++) {
    const seed = random.seed;
    const level = random.next(1, 100);
    const gen = random.next(1, 8) as GenerationNum;

    const base: Partial<StatsTable> = {};
    const ivs: Partial<StatsTable> = {};
    const evs: Partial<StatsTable> = {};
    const stats: Partial<StatsTable> = {};
    const nature = gen >= 3 ? random.sample([...data.NATURES]) : undefined;

    let spread: Spread | undefined;
    let calced: Partial<StatsTable> | undefined;

    try {
      let total = 510;
      // NOTE: we iterate to ensure HP gets handled last after all of the other IVs have been
      // rolled so that if we need to compute the expected HP DV in RBY/GSC we are able to
      const order = [...data.STATS].reverse();
      for (const stat of order) {
        if (gen === 1 && stat === 'spa') {
          base.spa = base.spd;
          ivs.spa = ivs.spd;
          evs.spa = evs.spd;
          stats.spa = stats.spd;
          continue;
        }
        base[stat] = random.next(5, 255);
        ivs[stat] = stat === 'hp' && gen < 3
          ? data.STATS.toIV(data.STATS.getHPDV(ivs))
          : random.next(0, 31);
        evs[stat] = random.next(0, gen >= 3 ? Math.min(total, 252) : 252);
        total -= evs[stat];
        stats[stat] =
          data.STATS.calc(gen, stat, base[stat], ivs[stat], evs[stat], level, nature);
      }
      if (gen >= 3) assert(total >= 0);

      spread = Stats.toSpread(stats as StatsTable, base as StatsTable, gen, level)!;
      assert(spread !== undefined);
      const s = spread;
      let n: data.Nature | undefined;
      if (gen < 3) {
        assert(s.nature === undefined);
      } else {
        assert(s.nature !== undefined);
        n = data.NATURES.get(s.nature);
        if (!nature!.plus && !nature!.minus) {
          // Ensure we also use a neutral Nature if the generated stats came from a spread
          // with a neutral Nature - EPOké want to have the flexibility to optimize later
          assert(n.plus === undefined);
          assert(n.minus === undefined);
        }
      }

      total = 0;
      calced = {};
      for (const stat of data.STATS) {
        if (s.ivs[stat]) {
          assert(s.ivs[stat] >= 0);
          assert(s.ivs[stat] <= 31);
        }
        if (s.evs[stat]) {
          assert(s.evs[stat] >= 0);
          assert(s.evs[stat] <= 255);
          total += s.evs[stat];
        }
        calced[stat] =
          data.STATS.calc(gen, stat, base[stat]!, s.ivs[stat], s.evs[stat], level, n);
      }
      assert(total <= (gen >= 3 ? 510 : 255 * 5));

      assert.deepStrictEqual(calced, stats);
    } catch (err) {
      const t = {nature: nature?.name, ivs, evs};
      const compact = {style: 'compact' as const};
      const options = {...compact, separator: ' '};
      console.log(
        `Seed: ${seed} (${i + 1}/${N})\n` +
        `Generation: ${gen}\n` +
        `Level: ${level}\n` +
        `Base Stats: ${Stats.display(base as StatsTable, gen, compact)}\n` +
        '------------------------------\n' +
        `Original: ${Spread.display(t, gen, options)}\n` +
        `Computed: ${spread ? Spread.display(spread, gen,) : 'N/A'}\n` +
        '------------------------------\n' +
        `Original: ${Stats.display(stats as StatsTable, gen, options)}\n` +
        `Computed: ${calced ? Stats.display(calced as StatsTable, gen, compact) : 'N/A'}\n`
      );
      throw err;
    }
  }
}
