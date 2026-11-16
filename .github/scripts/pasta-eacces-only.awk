# Classifies a failed rootless `podman run` as the known Alpine pasta failure.
#
# Exits 0 iff the output holds a pasta failure whose diagnostics -- the
# non-blank lines after podman's "pasta failed with exit code N:" header -- are
# all, and at least one, "Permission denied". Anything else exits 1: no pasta
# header, a header with nothing after it, or even one non-EACCES diagnostic.
#
# Which paths get denied is a property of the host kernel, not of pasta or this
# package, so no specific path is matched. See acceptance.sh (rootless section)
# and docs/acceptance.md for why that failure is tolerated at all.
#
# Runs under BusyBox awk in the Alpine acceptance container, so it is kept to
# POSIX awk. pasta-eacces-only-test.sh exercises it under that awk.
#
# Usage: awk -f pasta-eacces-only.awk <podman output file>

/pasta failed with exit code [0-9]+:[[:space:]]*$/ { inblock = 1; seen = 1; next }

inblock && NF {
  n++
  if ($0 !~ /: Permission denied$/) bad = 1
}

END { exit !(seen && n > 0 && !bad) }
