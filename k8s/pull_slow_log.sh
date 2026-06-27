
#!/bin/sh

namespace="pingraph-shared4-prod"
begin_time="2026-06-26T22:30:00"
end_time="2026-06-26T23:30:00"

out="slowlog_${namespace}_${begin_time}_${end_time}.log"
: > "$out"

kubectl -n "$namespace" get pod --no-headers \
| awk '{print $1}' \
| grep 'tidb' \
| grep -v 'dashboard' \
| while read pod; do
  echo ">>> collecting from pod: $pod" >&2

  {
    echo "######## POD: $pod ########"

    kubectl -n "$namespace" exec "$pod" -- sh -c "
      if [ ! -f /var/log/tidb/slowlog ]; then
        exit 0
      fi

      awk -v start='$begin_time' -v end='$end_time' '
        /^# Time:/ {
          t=\$3
          sub(/Z$/, \"\", t)
          sub(/\\..*/, \"\", t)
          keep = (t >= start && t <= end)
        }
        keep { print }
      ' /var/log/tidb/slowlog
    "

    echo
  } >> "$out"
done

echo "done: $out"
