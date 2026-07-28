#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage: $0 --phase sermon|worship --output-dir DIR [--replace]"
}

phase=""
output_directory=""
replace_existing=0
while (( $# > 0 )); do
  case "$1" in
    --phase) phase="${2:-}"; shift 2 ;;
    --output-dir) output_directory="${2:-}"; shift 2 ;;
    --replace) replace_existing=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print -u2 "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ ( "${phase}" != "sermon" && "${phase}" != "worship" ) ||
      -z "${output_directory}" ]]; then
  usage
  exit 2
fi

script_directory="${0:A:h}"
template_directory="${script_directory:h}/evidence-templates"
templates=(
  external-failover
  latency-lipsync
  runtime-resilience
  replay-comparison
  rollout-observation
)
for name in "${templates[@]}"; do
  if [[ ! -s "${template_directory}/${name}.json" ]]; then
    print -u2 "Production evidence template is missing: ${template_directory}/${name}.json"
    exit 3
  fi
done

/bin/mkdir -p "${output_directory}"
output_directory="$(/bin/realpath "${output_directory}")"
for name in "${templates[@]}"; do
  output="${output_directory}/${name}.json"
  if [[ -e "${output}" ]] && (( ! replace_existing )); then
    print -u2 "Draft already exists; pass --replace to overwrite it: ${output}"
    exit 3
  fi
done

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for name in "${templates[@]}"; do
  output="${output_directory}/${name}.json"
  /bin/cp "${template_directory}/${name}.json" "${output}"
  /usr/bin/plutil -replace phase -string "${phase}" "${output}"
  /usr/bin/plutil -replace completedAtUTC -string "${completed_at}" "${output}"
done
if [[ "${phase}" == "worship" ]]; then
  /usr/bin/plutil -insert comparisons.0.coverageTags.10 -string dense-worship \
    "${output_directory}/replay-comparison.json"
fi

print "Created ${phase} production-evidence drafts in ${output_directory}."
print "Fill every REPLACE path/measurement/judgment, then run scripts/finalize-production-evidence.sh."
