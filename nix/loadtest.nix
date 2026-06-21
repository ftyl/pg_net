{ writeShellScriptBin, psrecord, writers, python3Packages } :

let
  psrecordToMd =
    writers.writePython3 "psrecord-to-md"
      {
        libraries = [ python3Packages.pandas python3Packages.tabulate ];
      }
      ''
        import sys
        import pandas as pd
        import re

        HEADER_SPLIT = re.compile(r"\s{2,}")

        raw_lines = sys.stdin.read().splitlines()

        header_line = next(
            (line for line in raw_lines if line.lstrip().startswith("# Elapsed time")), None
        )
        if header_line is None:
            # Fallback note (e.g. worker exited before monitor attach). Render
            # plainly instead of failing or producing an empty table.
            if raw_lines:
                print("```")
                print("\n".join(raw_lines))
                print("```")
                sys.exit(0)
            sys.exit("Error: no header line found in input.")

        columns = HEADER_SPLIT.split(header_line.lstrip("#").strip())

        data_lines = [
            line.strip()
            for line in raw_lines
            if line.strip() and not line.lstrip().startswith("#")
        ]

        data_rows = [HEADER_SPLIT.split(line) for line in data_lines]

        df = pd.DataFrame(data_rows, columns=columns, dtype=str)

        df.to_markdown(sys.stdout, index=False, tablefmt="github")
      '';

  csvToMd =
    writers.writePython3 "csv-to-md"
      {
        libraries = [ python3Packages.pandas python3Packages.tabulate ];
      }
      ''
        import sys
        import pandas as pd

        pd.read_csv(sys.stdin) \
          .fillna("") \
          .convert_dtypes() \
          .to_markdown(sys.stdout, index=False, floatfmt='.0f')
      '';

in

writeShellScriptBin "net-loadtest" ''
  set -euo pipefail

  reqs=""
  batch_size_opt=""

  load_dir=test/load
  mkdir -p $load_dir
  echo "*" >> $load_dir/.gitignore

  record_result=$load_dir/psrecord.md
  query_result=$load_dir/query_out.md

  query_csv=$load_dir/query.csv
  record_log=$load_dir/psrecord.log

  if [ -n "''${1:-}" ]; then
    reqs="$1"
  fi

  if [ -n "''${2:-}" ]; then
    batch_size_opt="-c pg_net.batch_size=$2"
  fi

  net-with-nginx xpg --options "-c log_min_messages=WARNING $batch_size_opt" \
    psql -c "call wait_for_many_gets($reqs)" -c "\pset format csv" -c "\o $query_csv" -c "select * from run" > /dev/null &
  load_pid=$!

  bgworker_pid_file=build-17/bgworker.pid
  bgworker_pid=""
  # The worker can start later than harness boot, so keep polling for a live
  # worker pid while the load query process is still running.
  while kill -0 "$load_pid" 2>/dev/null; do
    if [ -f "$bgworker_pid_file" ]; then
      candidate_pid=$(<"$bgworker_pid_file")
      if [ -n "$candidate_pid" ] && kill -0 "$candidate_pid" 2>/dev/null; then
        bgworker_pid="$candidate_pid"
        break
      fi
    fi
    sleep 0.2
  done

  if [ -n "$bgworker_pid" ] && kill -0 "$bgworker_pid" 2>/dev/null; then
    if ! ${psrecord}/bin/psrecord "$bgworker_pid" --interval 1 --log "$record_log" > /dev/null; then
      echo "# psrecord failed while monitoring pid $bgworker_pid" > "$record_log"
    fi
  elif [ -f "$bgworker_pid_file" ]; then
    if [ -n "$bgworker_pid" ]; then
      echo "# background worker pid $bgworker_pid exited before psrecord started" > "$record_log"
    else
      echo "# background worker pid file present but empty at $bgworker_pid_file" > "$record_log"
    fi
  else
    echo "# no background worker pid file at $bgworker_pid_file while load process ran" > "$record_log"
  fi

  # Always wait for the load query process to finish before reading output.
  wait "$load_pid"

  echo -e "## Loadtest results\n"
  cat $query_csv  | ${csvToMd}

  echo -e "\n\n## Loadtest elapsed seconds vs CPU/MEM\n"
  cat $record_log | ${psrecordToMd}
''
