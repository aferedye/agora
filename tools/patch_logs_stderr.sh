#!/usr/bin/env bash
set -euo pipefail

cp dubash "dubash.bak.$(date +%s)"

# Remplace la fonction log pour écrire sur stderr (et log file)
awk '
  BEGIN{patched=0}
  /^log\(\)\{/ {print; getline; 
    print "  local ts; ts=\"$(date '+%Y-%m-%d %H:%M:%S')\"";
    print "  local line=\"[$ts] \"$*";
    # skip old body lines until closing brace
    while (getline > 0) {
      if ($0 ~ /^\}/) { 
        print "  echo \"$line\" | tee -a \"$LOG_FILE\" >&2";
        print "}";
        patched=1; 
        break;
      }
    }
    next
  }
  {print}
  END{ if(!patched) exit 1 }
' dubash > dubash.new || { echo "Patch failed"; exit 1; }

mv dubash.new dubash
chmod +x dubash
echo "✅ dubash: logs -> stderr"
