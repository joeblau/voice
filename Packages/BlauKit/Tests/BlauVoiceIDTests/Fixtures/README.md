# Voice ID fixtures

## `Speakers/`: the speaker fixture set

Twelve read-speech clips, three from each of four speakers, from the
[CMU ARCTIC](http://festvox.org/cmu_arctic/) databases (version 0.95):

| Speaker | Voice | Clips |
| --- | --- | --- |
| `bdl` | US English, male | `arctic_a0001` to `a0003` |
| `rms` | US English, male | `arctic_a0001` to `a0003` |
| `slt` | US English, female | `arctic_a0001` to `a0003` |
| `clb` | US English, female | `arctic_a0001` to `a0003` |

Files are named `<speaker>_<utterance>.wav`: 16 kHz, mono, 16-bit PCM,
2.9 to 3.5 s each. Every speaker reads the same three sentences, so the
same-speaker and different-speaker comparisons can't be explained by what is
said. Two speakers of each sex keep the different-speaker pairs hard.

**Modifications** (as the license asks, marked here): each original
recording was trimmed of leading and trailing silence (10 ms frames below 3%
of the clip's peak RMS level, keeping 50 ms either side). The remaining
samples are unchanged.

The tests that use these clips with the real WeSpeaker model are opt-in (see
`SpeakerEmbeddingFixtureTests` and docs/benchmarks.md). The voice ID
evaluation harness (#48) can reuse them.

### License

```
This voice is free for use for any purpose (commercial or otherwise)
subject to the pretty light restrictions detailed below.

                     Carnegie Mellon University
                        Copyright (c) 2003
                        All Rights Reserved.

 Permission to use, copy, modify,  and licence this software and its
 documentation for any purpose, is hereby granted without fee,
 subject to the following conditions:
  1. The code must retain the above copyright notice, this list of
     conditions and the following disclaimer.
  2. Any modifications must be clearly marked as such.
  3. Original authors' names are not deleted.

 THE AUTHORS OF THIS WORK DISCLAIM ALL WARRANTIES WITH REGARD TO
 THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
 AND FITNESS, IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY
 SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
 AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
 ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
 THIS SOFTWARE.

 See http://www.festvox.org/cmu_arctic/ for more details
```

The CMU ARCTIC databases were built by John Kominek and Alan W Black at the
Language Technologies Institute, Carnegie Mellon University.
