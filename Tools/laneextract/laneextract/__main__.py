import sys

from . import analyse, report, songbass

USAGE = """usage:
  python3 -m laneextract report  <midi_dir>  <out_dir>                         # E0/E1 source corpus
  python3 -m laneextract factory <songs_dir> <out_dir>                         # E1 target drum features
  python3 -m laneextract analyse <midi_dir> <songs_dir> <app_dir> <out_dir>    # E2 link, chords, key, interval bass
  python3 -m laneextract songpack <midi_songs_dir> <out_dir>                   # E6 bass for the songs' own drums"""

if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "report":
        report.run(a[1], a[2])
    elif len(a) == 3 and a[0] == "factory":
        report.run_factory(a[1], a[2])
    elif len(a) == 3 and a[0] == "songpack":
        songbass.run(a[1], a[2])
    elif len(a) == 5 and a[0] == "analyse":
        analyse.run(a[1], a[2], a[3], a[4])
    else:
        print(USAGE)
        sys.exit(2)
