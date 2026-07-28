#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --external-failover PATH --latency-lipsync PATH"
  print -u2 "     --runtime-resilience PATH --replay-comparison PATH"
  print -u2 "     [--expected-manifest PATH] [--expected-candidate-commit SHA]"
  print -u2 "     [--expected-phase sermon|worship]"
  print -u2 "     [--require-approved-replay]"
}

external_failover_path=""
latency_lipsync_path=""
runtime_resilience_path=""
replay_comparison_path=""
expected_manifest_path=""
expected_manifest_sha=""
expected_candidate_commit=""
expected_phase=""
require_approved_replay=0

while (( $# > 0 )); do
  case "$1" in
    --external-failover) external_failover_path="${2:-}"; shift 2 ;;
    --latency-lipsync) latency_lipsync_path="${2:-}"; shift 2 ;;
    --runtime-resilience) runtime_resilience_path="${2:-}"; shift 2 ;;
    --replay-comparison) replay_comparison_path="${2:-}"; shift 2 ;;
    --expected-manifest) expected_manifest_path="${2:-}"; shift 2 ;;
    --expected-candidate-commit) expected_candidate_commit="${2:-}"; shift 2 ;;
    --expected-phase) expected_phase="${2:-}"; shift 2 ;;
    --require-approved-replay) require_approved_replay=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print -u2 "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${external_failover_path}" ||
      -z "${latency_lipsync_path}" ||
      -z "${runtime_resilience_path}" ||
      -z "${replay_comparison_path}" ]]; then
  usage
  exit 2
fi
if [[ -n "${expected_candidate_commit}" &&
      ! "${expected_candidate_commit}" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "Expected candidate commit must be a 40-character lowercase Git SHA."
  exit 2
fi
if [[ -n "${expected_phase}" &&
      "${expected_phase}" != "sermon" &&
      "${expected_phase}" != "worship" ]]; then
  print -u2 "Expected phase must be sermon or worship."
  exit 2
fi
if [[ -n "${expected_manifest_path}" ]]; then
  if [[ ! -s "${expected_manifest_path}" ]]; then
    print -u2 "Expected full-check manifest is missing or empty: ${expected_manifest_path}"
    exit 3
  fi
  expected_manifest_sha="$(/usr/bin/shasum -a 256 "${expected_manifest_path}" | /usr/bin/awk '{print $1}')"
  manifest_hardware="$(/usr/bin/plutil -extract hardwareProofPassed raw -o - "${expected_manifest_path}" 2>/dev/null || true)"
  manifest_scene="$(/usr/bin/plutil -extract scene raw -o - "${expected_manifest_path}" 2>/dev/null || true)"
  if [[ "${manifest_hardware}" != "true" ||
        ( "${manifest_scene}" != "sermon" && "${manifest_scene}" != "worship" ) ]]; then
    print -u2 "Expected manifest must be passed sermon or worship hardware proof."
    exit 3
  fi
  if [[ -n "${expected_phase}" && "${manifest_scene}" != "${expected_phase}" ]]; then
    print -u2 "Expected manifest scene does not match the selected phase."
    exit 3
  fi
fi

fail() {
  print -u2 "Production evidence invalid: $*"
  exit 4
}

extract() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

require_string() {
  local file="$1"
  local key="$2"
  local label="$3"
  local value
  value="$(extract "${file}" "${key}" || true)"
  if [[ -z "${value}" || "${value}" == *[[:cntrl:]]* || ${#value} -gt 1000 ]]; then
    fail "${label} must be a non-empty, single-line string."
  fi
  REPLY="${value}"
}

require_regex() {
  local file="$1"
  local key="$2"
  local pattern="$3"
  local label="$4"
  local value
  value="$(extract "${file}" "${key}" || true)"
  if [[ ! "${value}" =~ "${pattern}" ]]; then
    fail "${label} has an invalid value."
  fi
  REPLY="${value}"
}

require_boolean_value() {
  local file="$1"
  local key="$2"
  local label="$3"
  local value
  value="$(extract "${file}" "${key}" || true)"
  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    fail "${label} must be a boolean."
  fi
  REPLY="${value}"
}

require_boolean() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  require_boolean_value "${file}" "${key}" "${label}"
  if [[ "${REPLY}" != "${expected}" ]]; then
    fail "${label} must be ${expected}."
  fi
}

require_integer_between() {
  local file="$1"
  local key="$2"
  local minimum="$3"
  local maximum="$4"
  local label="$5"
  local value
  value="$(extract "${file}" "${key}" || true)"
  if [[ ! "${value}" =~ '^[0-9]+$' ]] ||
      (( value < minimum || value > maximum )); then
    fail "${label} must be an integer from ${minimum} through ${maximum}."
  fi
  REPLY="${value}"
}

require_number_between() {
  local file="$1"
  local key="$2"
  local minimum="$3"
  local maximum="$4"
  local label="$5"
  local value
  value="$(extract "${file}" "${key}" || true)"
  if [[ ! "${value}" =~ '^-?[0-9]+([.][0-9]+)?$' ]] ||
      (( value < minimum || value > maximum )); then
    fail "${label} must be a number from ${minimum} through ${maximum}."
  fi
  REPLY="${value}"
}

require_array_count() {
  local file="$1"
  local key="$2"
  local minimum="$3"
  local maximum="$4"
  local label="$5"
  local value
  value="$(extract "${file}" "${key}" || true)"
  if [[ ! "${value}" =~ '^[0-9]+$' ]] ||
      (( value < minimum || value > maximum )); then
    fail "${label} must contain from ${minimum} through ${maximum} entries."
  fi
  REPLY="${value}"
}

verify_reference() {
  local report="$1"
  local prefix="$2"
  local label="$3"
  local path expected_sha expected_bytes observed_sha observed_bytes

  path="$(extract "${report}" "${prefix}.path" || true)"
  expected_sha="$(extract "${report}" "${prefix}.sha256" || true)"
  expected_bytes="$(extract "${report}" "${prefix}.bytes" || true)"
  if [[ "${path}" != /* ||
        ! "${expected_sha}" =~ '^[0-9a-f]{64}$' ||
        ! "${expected_bytes}" =~ '^[0-9]+$' ||
        ${expected_bytes:-0} -le 0 ||
        ! -s "${path}" ]]; then
    fail "${label} must reference a non-empty absolute path with SHA-256 and byte count."
  fi
  observed_sha="$(/usr/bin/shasum -a 256 "${path}" | /usr/bin/awk '{print $1}')"
  observed_bytes="$(/usr/bin/stat -f '%z' "${path}")"
  if [[ "${observed_sha}" != "${expected_sha}" ||
        "${observed_bytes}" != "${expected_bytes}" ]]; then
    fail "${label} attachment does not match its recorded SHA-256 and byte count."
  fi
  REPLY="${path}"
}

validate_common() {
  local report="$1"
  local proof_type="$2"
  local label="$3"
  local format_version observed_type completed_at report_manifest_sha report_phase

  if [[ ! -s "${report}" ]]; then
    fail "${label} report is missing or empty: ${report}"
  fi
  format_version="$(extract "${report}" formatVersion || true)"
  observed_type="$(extract "${report}" proofType || true)"
  completed_at="$(extract "${report}" completedAtUTC || true)"
  if [[ "${format_version}" != "1" || "${observed_type}" != "${proof_type}" ]]; then
    fail "${label} must use formatVersion 1 and proofType ${proof_type}."
  fi
  if [[ ! "${completed_at}" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]]; then
    fail "${label} completedAtUTC must be an RFC 3339 UTC timestamp."
  fi
  require_boolean "${report}" venueRig true "${label} venueRig"
  require_string "${report}" phase "${label} phase"
  report_phase="${REPLY}"
  if [[ "${report_phase}" != "sermon" && "${report_phase}" != "worship" ]]; then
    fail "${label} phase must be sermon or worship."
  fi
  if [[ -n "${expected_phase}" && "${report_phase}" != "${expected_phase}" ]]; then
    fail "${label} belongs to ${report_phase}, not the selected ${expected_phase} phase."
  fi
  require_regex "${report}" fullCheckManifestSHA256 '^[0-9a-f]{64}$' "${label} fullCheckManifestSHA256"
  report_manifest_sha="${REPLY}"
  if [[ -n "${expected_manifest_sha}" ]]; then
    if [[ "${report_manifest_sha}" != "${expected_manifest_sha}" ]]; then
      fail "${label} is not bound to the selected full-check manifest."
    fi
  fi
}

validate_external_failover() {
  local report="$1"
  local ceiling test_count index prefix test_id switch_seconds silent_seconds peak
  local primary_input backup_input
  local -A seen_tests
  local -a required_tests
  required_tests=(
    force-quit-app
    stop-dvs-core-audio
    disconnect-dante-network
    remove-output-device
    power-off-mac
  )

  validate_common "${report}" external-failover "external failover"
  require_string "${report}" switchModel "external failover switchModel"
  require_string "${report}" primaryEncoderInput "external failover primaryEncoderInput"
  primary_input="${REPLY}"
  require_string "${report}" backupEncoderInput "external failover backupEncoderInput"
  backup_input="${REPLY}"
  if [[ "${primary_input}" == "${backup_input}" ]]; then
    fail "external failover encoder inputs must be distinct."
  fi
  require_string "${report}" heartbeatMechanism "external failover heartbeatMechanism"
  require_boolean "${report}" backupIsDefaultState true "external failover backupIsDefaultState"
  require_boolean "${report}" manualReturnOnly true "external failover manualReturnOnly"
  require_boolean "${report}" broadcastIsolationConfirmed true "external failover broadcastIsolationConfirmed"
  require_boolean "${report}" manualReturnVerified true "external failover manualReturnVerified"
  require_number_between "${report}" truePeakCeilingDbTP -30 -1 "external failover truePeakCeilingDbTP"
  ceiling="${REPLY}"
  verify_reference "${report}" wiringDiagram "external failover wiringDiagram"
  require_array_count "${report}" tests 5 5 "external failover tests"
  test_count="${REPLY}"

  integer index=0
  while (( index < test_count )); do
    prefix="tests.${index}"
    require_string "${report}" "${prefix}.id" "external failover test ${index} id"
    test_id="${REPLY}"
    if [[ -n "${seen_tests[${test_id}]:-}" ]]; then
      fail "external failover test id is duplicated: ${test_id}."
    fi
    seen_tests[${test_id}]=1
    require_boolean "${report}" "${prefix}.passed" true "${test_id} passed"
    require_boolean "${report}" "${prefix}.programAudioPresent" true "${test_id} programAudioPresent"
    require_boolean "${report}" "${prefix}.bothEncoderInputsRecorded" true "${test_id} bothEncoderInputsRecorded"
    require_boolean "${report}" "${prefix}.selectedOutputRecorded" true "${test_id} selectedOutputRecorded"
    require_boolean "${report}" "${prefix}.speechIntelligible" true "${test_id} speechIntelligible"
    require_boolean "${report}" "${prefix}.fohReturnLeakDetected" false "${test_id} fohReturnLeakDetected"
    require_boolean "${report}" "${prefix}.oscillationDetected" false "${test_id} oscillationDetected"
    require_boolean "${report}" "${prefix}.stateVisible" true "${test_id} stateVisible"
    require_boolean "${report}" "${prefix}.heldBackupUntilManualReturn" true "${test_id} heldBackupUntilManualReturn"
    require_number_between "${report}" "${prefix}.switchTimeSeconds" 0 2 "${test_id} switchTimeSeconds"
    switch_seconds="${REPLY}"
    require_number_between "${report}" "${prefix}.maxSilentGapSeconds" 0 2 "${test_id} maxSilentGapSeconds"
    silent_seconds="${REPLY}"
    require_number_between "${report}" "${prefix}.selectedOutputTruePeakDbTP" -100 0 "${test_id} selectedOutputTruePeakDbTP"
    peak="${REPLY}"
    if (( peak > ceiling )); then
      fail "${test_id} selected output peak ${peak} dBTP exceeds the ${ceiling} dBTP ceiling."
    fi
    verify_reference "${report}" "${prefix}.recording" "external failover ${test_id} recording"
    index="$(( index + 1 ))"
  done

  for test_id in "${required_tests[@]}"; do
    if [[ -z "${seen_tests[${test_id}]:-}" ]]; then
      fail "external failover is missing required kill test: ${test_id}."
    fi
  done
}

validate_latency_lipsync() {
  local report="$1"
  local audio_ms video_ms delay_ms target delta expected_delay difference
  local residual_ms acceptance_limit drift_duration drift_change drift_rate drift_limit
  local drift_control expected_drift_rate drift_difference

  validate_common "${report}" latency-lipsync "latency/lip-sync"
  require_boolean "${report}" productionRouteVerified true "latency/lip-sync productionRouteVerified"
  require_string "${report}" measurementMethod "latency/lip-sync measurementMethod"
  require_integer_between "${report}" warmupMinutes 30 1440 "latency/lip-sync warmupMinutes"
  require_integer_between "${report}" sampleCount 10 10000 "latency/lip-sync sampleCount"
  require_number_between "${report}" audioPathMedianMs 0 60000 "latency/lip-sync audioPathMedianMs"
  audio_ms="${REPLY}"
  require_number_between "${report}" videoPathMedianMs 0 60000 "latency/lip-sync videoPathMedianMs"
  video_ms="${REPLY}"
  require_string "${report}" compensation.target "latency/lip-sync compensation.target"
  target="${REPLY}"
  if [[ "${target}" != "audio" && "${target}" != "video" && "${target}" != "none" ]]; then
    fail "latency/lip-sync compensation.target must be audio, video, or none."
  fi
  require_number_between "${report}" compensation.delayMs 0 60000 "latency/lip-sync compensation.delayMs"
  delay_ms="${REPLY}"

  delta="$(( video_ms - audio_ms ))"
  if (( delta > 0.5 )); then
    expected_delay="${delta}"
    [[ "${target}" == "audio" ]] ||
      fail "latency/lip-sync must delay audio when video is slower."
  elif (( delta < -0.5 )); then
    expected_delay="$(( -delta ))"
    [[ "${target}" == "video" ]] ||
      fail "latency/lip-sync must delay video when audio is slower."
  else
    expected_delay=0
    [[ "${target}" == "none" ]] ||
      fail "latency/lip-sync compensation.target must be none when path medians are aligned."
  fi
  difference="$(( delay_ms - expected_delay ))"
  (( difference < 0 )) && difference="$(( -difference ))"
  if (( difference > 1.0 )); then
    fail "latency/lip-sync compensation differs from the measured path delta by more than 1 ms."
  fi

  require_number_between "${report}" venueAcceptanceLimitMs 1 20 "latency/lip-sync venueAcceptanceLimitMs"
  acceptance_limit="${REPLY}"
  require_number_between "${report}" residualMedianOffsetMs -60000 60000 "latency/lip-sync residualMedianOffsetMs"
  residual_ms="${REPLY}"
  if (( residual_ms < -acceptance_limit || residual_ms > acceptance_limit )); then
    fail "latency/lip-sync residual offset exceeds the venue acceptance limit."
  fi
  require_string "${report}" clockTopology "latency/lip-sync clockTopology"
  require_integer_between "${report}" inputBufferFrames 1 1048576 "latency/lip-sync inputBufferFrames"
  require_integer_between "${report}" outputBufferFrames 1 1048576 "latency/lip-sync outputBufferFrames"
  require_integer_between "${report}" inputDeviceLatencyFrames 0 1048576 "latency/lip-sync inputDeviceLatencyFrames"
  require_integer_between "${report}" outputDeviceLatencyFrames 0 1048576 "latency/lip-sync outputDeviceLatencyFrames"
  require_integer_between "${report}" separateOutputPrebufferFrames 0 4194304 "latency/lip-sync separateOutputPrebufferFrames"
  require_integer_between "${report}" driftObservation.durationSeconds 7200 604800 "latency/lip-sync drift duration"
  drift_duration="${REPLY}"
  require_integer_between "${report}" driftObservation.syncEventCount 2 10000 "latency/lip-sync drift syncEventCount"
  require_number_between "${report}" driftObservation.offsetChangeMs -60000 60000 "latency/lip-sync drift offsetChangeMs"
  drift_change="${REPLY}"
  require_number_between "${report}" driftObservation.msPerHour -60000 60000 "latency/lip-sync drift msPerHour"
  drift_rate="${REPLY}"
  expected_drift_rate="$(( drift_change * 3600.0 / drift_duration ))"
  drift_difference="$(( drift_rate - expected_drift_rate ))"
  (( drift_difference < 0 )) && drift_difference="$(( -drift_difference ))"
  if (( drift_difference > 0.1 )); then
    fail "latency/lip-sync drift msPerHour does not match offsetChangeMs and durationSeconds."
  fi
  require_number_between "${report}" driftObservation.limitMsPerHour 0.1 20 "latency/lip-sync drift limitMsPerHour"
  drift_limit="${REPLY}"
  if (( drift_rate < -drift_limit || drift_rate > drift_limit )); then
    fail "latency/lip-sync clock drift exceeds its declared limit."
  fi
  require_string "${report}" driftObservation.control "latency/lip-sync drift control"
  drift_control="${REPLY}"
  if [[ "${drift_control}" != "shared-clock" &&
        "${drift_control}" != "aggregate-device-drift-correction" &&
        "${drift_control}" != "bounded-asrc" ]]; then
    fail "latency/lip-sync drift control must be shared-clock, aggregate-device-drift-correction, or bounded-asrc."
  fi
  require_boolean "${report}" driftObservation.withinLimit true "latency/lip-sync drift withinLimit"
  verify_reference "${report}" rawMeasurements "latency/lip-sync rawMeasurements"
  verify_reference "${report}" testRecording "latency/lip-sync testRecording"
}

validate_runtime_resilience() {
  local report="$1"
  local test_count index prefix test_id
  local -A seen_tests
  local -a required_tests
  required_tests=(
    callback-stall-recovery
    output-device-reattach
    recording-resume
    encoder-egress-alerts
    launchagent-relaunch
    operator-stop-no-restart
    external-failover-handoff
  )

  validate_common "${report}" runtime-resilience "runtime resilience"
  require_array_count "${report}" tests 7 7 "runtime resilience tests"
  test_count="${REPLY}"
  integer index=0
  while (( index < test_count )); do
    prefix="tests.${index}"
    require_string "${report}" "${prefix}.id" "runtime resilience test ${index} id"
    test_id="${REPLY}"
    if [[ -n "${seen_tests[${test_id}]:-}" ]]; then
      fail "runtime resilience test id is duplicated: ${test_id}."
    fi
    seen_tests[${test_id}]=1
    require_boolean "${report}" "${prefix}.passed" true "${test_id} passed"
    case "${test_id}" in
      callback-stall-recovery)
        require_number_between "${report}" "${prefix}.unhealthyGraceSeconds" 2 10 "${test_id} unhealthyGraceSeconds"
        require_boolean "${report}" "${prefix}.engineRestarted" true "${test_id} engineRestarted"
        ;;
      output-device-reattach)
        require_boolean "${report}" "${prefix}.boundedBackoffObserved" true "${test_id} boundedBackoffObserved"
        require_boolean "${report}" "${prefix}.routeRecovered" true "${test_id} routeRecovered"
        ;;
      recording-resume)
        require_boolean "${report}" "${prefix}.newRecordingDirectoryCreated" true "${test_id} newRecordingDirectoryCreated"
        require_boolean "${report}" "${prefix}.wavHeadersValid" true "${test_id} wavHeadersValid"
        ;;
      encoder-egress-alerts)
        require_boolean "${report}" "${prefix}.staleResponseRejected" true "${test_id} staleResponseRejected"
        require_boolean "${report}" "${prefix}.unhealthyResponseRejected" true "${test_id} unhealthyResponseRejected"
        require_boolean "${report}" "${prefix}.desktopCriticalAlertObserved" true "${test_id} desktopCriticalAlertObserved"
        require_boolean "${report}" "${prefix}.remoteCriticalAlertObserved" true "${test_id} remoteCriticalAlertObserved"
        ;;
      launchagent-relaunch)
        require_boolean "${report}" "${prefix}.applicationRelaunched" true "${test_id} applicationRelaunched"
        require_boolean "${report}" "${prefix}.sessionResumed" true "${test_id} sessionResumed"
        require_boolean "${report}" "${prefix}.captureResumed" true "${test_id} captureResumed"
        ;;
      operator-stop-no-restart)
        require_boolean "${report}" "${prefix}.recoveryDisarmed" true "${test_id} recoveryDisarmed"
        require_boolean "${report}" "${prefix}.automaticRestartObserved" false "${test_id} automaticRestartObserved"
        ;;
      external-failover-handoff)
        require_boolean "${report}" "${prefix}.allKillTestsPassed" true "${test_id} allKillTestsPassed"
        require_boolean "${report}" "${prefix}.heldBackupUntilManualReturn" true "${test_id} heldBackupUntilManualReturn"
        ;;
      *)
        fail "runtime resilience contains unknown test id: ${test_id}."
        ;;
    esac
    verify_reference "${report}" "${prefix}.evidence" "runtime resilience ${test_id} evidence"
    index="$(( index + 1 ))"
  done

  for test_id in "${required_tests[@]}"; do
    if [[ -z "${seen_tests[${test_id}]:-}" ]]; then
      fail "runtime resilience is missing required drill: ${test_id}."
    fi
  done
}

validate_replay_metrics() {
  local metrics="$1"
  local expected_crc="$2"
  local approved="$3"
  local label="$4"
  local schema crc safety output_finite reference_available decision_ticks
  local sample_rate source_channels input_channels frames duration roles_count
  local expected_source_channels control_interval expected_ticks duration_difference
  local output_peak

  schema="$(extract "${metrics}" schemaVersion || true)"
  crc="$(extract "${metrics}" sourceCrc32 || true)"
  if [[ "${schema}" != "2" || "${crc:l}" != "${expected_crc:l}" ]]; then
    fail "${label} must be replay metrics schema 2 with the selected source CRC32."
  fi
  require_boolean_value "${metrics}" safetyPassed "${label} safetyPassed"
  safety="${REPLY}"
  require_boolean_value "${metrics}" outputFinite "${label} outputFinite"
  output_finite="${REPLY}"
  require_boolean_value "${metrics}" referenceAvailable "${label} referenceAvailable"
  reference_available="${REPLY}"
  require_integer_between "${metrics}" sampleRate 8000 384000 "${label} sampleRate"
  sample_rate="${REPLY}"
  require_integer_between "${metrics}" blockSize 1 65536 "${label} blockSize"
  require_integer_between "${metrics}" sourceChannels 1 66 "${label} sourceChannels"
  source_channels="${REPLY}"
  require_integer_between "${metrics}" inputChannels 1 64 "${label} inputChannels"
  input_channels="${REPLY}"
  require_integer_between "${metrics}" frames 1 2147483647 "${label} frames"
  frames="${REPLY}"
  require_number_between "${metrics}" durationSeconds 300 86400 "${label} durationSeconds"
  duration="${REPLY}"
  require_integer_between "${metrics}" decisionTicks 1 2147483647 "${label} decisionTicks"
  decision_ticks="${REPLY}"
  require_array_count "${metrics}" roles "${input_channels}" "${input_channels}" "${label} roles"
  roles_count="${REPLY}"
  require_array_count "${metrics}" stereoPairs 0 32 "${label} stereoPairs"
  require_string "${metrics}" scene "${label} scene"
  if [[ "${REPLY}" != "sermon" && "${REPLY}" != "worship" ]]; then
    fail "${label} scene must be sermon or worship."
  fi
  expected_source_channels="${input_channels}"
  [[ "${reference_available}" == "true" ]] &&
    expected_source_channels="$(( input_channels + 2 ))"
  if (( source_channels != expected_source_channels )); then
    fail "${label} source channel count is inconsistent with inputChannels and referenceAvailable."
  fi
  control_interval="$(( sample_rate / 20 ))"
  (( control_interval < 1 )) && control_interval=1
  expected_ticks="$(( (frames + control_interval - 1) / control_interval ))"
  if (( decision_ticks != expected_ticks )); then
    fail "${label} decisionTicks does not match its frame count and 20 Hz control clock."
  fi
  duration_difference="$(( duration - (frames * 1.0 / sample_rate) ))"
  (( duration_difference < 0 )) && duration_difference="$(( -duration_difference ))"
  if (( duration_difference > 0.01 )); then
    fail "${label} durationSeconds does not match frames and sampleRate."
  fi
  require_number_between "${metrics}" outputSamplePeakDbfs -200 0 "${label} outputSamplePeakDbfs"
  output_peak="${REPLY}"
  require_number_between "${metrics}" outputIntegratedLufs -100 0 "${label} outputIntegratedLufs"
  require_number_between "${metrics}" outputShortTermLufs -100 0 "${label} outputShortTermLufs"
  require_number_between "${metrics}" maximumLimiterGainReductionDb 0 100 "${label} maximumLimiterGainReductionDb"
  if [[ "${approved}" == "true" &&
        ( "${safety}" != "true" ||
          "${output_finite}" != "true" ||
          "${reference_available}" != "true" ) ]]; then
    fail "${label} must be safe, finite, and reference-backed for approval."
  fi
  if [[ "${approved}" == "true" ]] && (( output_peak > -0.9 )); then
    fail "${label} output peak exceeds the replay evaluator's safety ceiling."
  fi
  REPLY="${decision_ticks}"
}

compare_replay_configuration() {
  local baseline_metrics="$1"
  local candidate_metrics="$2"
  local label="$3"
  local key baseline_value candidate_value
  local -a scalar_keys collection_keys
  scalar_keys=(scene sampleRate blockSize sourceChannels inputChannels frames decisionTicks)
  collection_keys=(roles stereoPairs)
  for key in "${scalar_keys[@]}"; do
    baseline_value="$(extract "${baseline_metrics}" "${key}" || true)"
    candidate_value="$(extract "${candidate_metrics}" "${key}" || true)"
    if [[ -z "${baseline_value}" || "${baseline_value}" != "${candidate_value}" ]]; then
      fail "${label} baseline and candidate render configuration differ at ${key}."
    fi
  done
  for key in "${collection_keys[@]}"; do
    baseline_value="$(/usr/bin/plutil -extract "${key}" xml1 -o - "${baseline_metrics}" 2>/dev/null || true)"
    candidate_value="$(/usr/bin/plutil -extract "${key}" xml1 -o - "${candidate_metrics}" 2>/dev/null || true)"
    if [[ -z "${baseline_value}" || "${baseline_value}" != "${candidate_value}" ]]; then
      fail "${label} baseline and candidate render configuration differ at ${key}."
    fi
  done
}

validate_decision_log() {
  local path="$1"
  local expected_ticks="$2"
  local label="$3"
  local line_count
  line_count="$(/usr/bin/awk 'END { print NR + 0 }' "${path}")"
  if [[ "${line_count}" != "${expected_ticks}" ]]; then
    fail "${label} line count does not match replay metrics decisionTicks."
  fi
  if ! /usr/bin/awk '
    NF == 0 || $0 !~ /^\{.*\}$/ { invalid = 1 }
    END { exit invalid || NR == 0 }
  ' "${path}"; then
    fail "${label} must contain one non-empty JSON object per control tick."
  fi
}

validate_replay_comparison() {
  local report="$1"
  local decision comparison_count index prefix corpus_id candidate_commit
  local baseline_crc candidate_crc baseline_metrics candidate_metrics
  local baseline_decisions candidate_decisions baseline_ticks candidate_ticks
  local tag_count tag_index tag check value approval_required report_phase
  local -A seen_corpora seen_coverage
  local -a approval_checks required_coverage
  approval_checks=(
    finiteOutput
    noUnexpectedSilence
    noClippingRegression
    noSustainedLimiterReduction
    noUnexplainedDecisionJumps
    loudnessWithinTolerance
    blindListeningPassed
  )
  required_coverage=(
    sermon
    prayer
    walk-in-out-playback
    quiet-speaker
    loud-speaker
    panel-handoff
    intentional-silence
    feedback-noise
    missing-channel
    repatched-role
  )
  report_phase="$(extract "${report}" phase || true)"
  if [[ "${report_phase}" == "worship" ]]; then
    required_coverage+=(dense-worship)
  fi

  validate_common "${report}" replay-comparison "replay comparison"
  require_string "${report}" reviewer "replay comparison reviewer"
  require_string "${report}" findings "replay comparison findings"
  require_string "${report}" decision "replay comparison decision"
  decision="${REPLY}"
  if [[ "${decision}" != "approved" && "${decision}" != "rejected" ]]; then
    fail "replay comparison decision must be approved or rejected."
  fi
  if (( require_approved_replay )) && [[ "${decision}" != "approved" ]]; then
    fail "an approved production acceptance requires an approved replay comparison."
  fi
  approval_required=false
  [[ "${decision}" == "approved" ]] && approval_required=true
  require_boolean "${report}" blindListeningCompleted true "replay comparison blindListeningCompleted"
  require_regex "${report}" baselineCommit '^[0-9a-f]{40}$' "replay comparison baselineCommit"
  require_regex "${report}" candidateCommit '^[0-9a-f]{40}$' "replay comparison candidateCommit"
  candidate_commit="${REPLY}"
  if [[ -n "${expected_candidate_commit}" &&
        "${candidate_commit}" != "${expected_candidate_commit}" ]]; then
    fail "replay comparison candidate commit does not match the accepted source commit."
  fi
  require_array_count "${report}" comparisons 1 10000 "replay comparison comparisons"
  comparison_count="${REPLY}"

  integer index=0
  while (( index < comparison_count )); do
    prefix="comparisons.${index}"
    require_string "${report}" "${prefix}.corpusID" "replay comparison corpus ID ${index}"
    corpus_id="${REPLY}"
    if [[ -n "${seen_corpora[${corpus_id}]:-}" ]]; then
      fail "replay comparison corpus ID is duplicated: ${corpus_id}."
    fi
    seen_corpora[${corpus_id}]=1
    require_boolean "${report}" "${prefix}.completeServiceReviewed" true "${corpus_id} completeServiceReviewed"
    require_array_count "${report}" "${prefix}.coverageTags" 1 20 "${corpus_id} coverageTags"
    tag_count="${REPLY}"
    integer tag_index=0
    while (( tag_index < tag_count )); do
      require_string "${report}" "${prefix}.coverageTags.${tag_index}" "${corpus_id} coverage tag ${tag_index}"
      tag="${REPLY}"
      seen_coverage[${tag}]=1
      tag_index="$(( tag_index + 1 ))"
    done
    require_regex "${report}" "${prefix}.baselineSourceCRC32" '^[0-9A-Fa-f]{8}$' "${corpus_id} baselineSourceCRC32"
    baseline_crc="${REPLY:l}"
    require_regex "${report}" "${prefix}.candidateSourceCRC32" '^[0-9A-Fa-f]{8}$' "${corpus_id} candidateSourceCRC32"
    candidate_crc="${REPLY:l}"
    if [[ "${baseline_crc}" != "${candidate_crc}" ]]; then
      fail "${corpus_id} baseline and candidate source CRC32 values differ."
    fi

    verify_reference "${report}" "${prefix}.baseline.program" "${corpus_id} baseline program"
    verify_reference "${report}" "${prefix}.baseline.metrics" "${corpus_id} baseline metrics"
    baseline_metrics="${REPLY}"
    verify_reference "${report}" "${prefix}.baseline.decisions" "${corpus_id} baseline decisions"
    baseline_decisions="${REPLY}"
    verify_reference "${report}" "${prefix}.candidate.program" "${corpus_id} candidate program"
    verify_reference "${report}" "${prefix}.candidate.metrics" "${corpus_id} candidate metrics"
    candidate_metrics="${REPLY}"
    verify_reference "${report}" "${prefix}.candidate.decisions" "${corpus_id} candidate decisions"
    candidate_decisions="${REPLY}"
    verify_reference "${report}" "${prefix}.referenceMix" "${corpus_id} reference mix"

    validate_replay_metrics "${baseline_metrics}" "${baseline_crc}" "${approval_required}" "${corpus_id} baseline metrics"
    baseline_ticks="${REPLY}"
    validate_replay_metrics "${candidate_metrics}" "${candidate_crc}" "${approval_required}" "${corpus_id} candidate metrics"
    candidate_ticks="${REPLY}"
    compare_replay_configuration "${baseline_metrics}" "${candidate_metrics}" "${corpus_id}"
    validate_decision_log "${baseline_decisions}" "${baseline_ticks}" "${corpus_id} baseline decisions"
    validate_decision_log "${candidate_decisions}" "${candidate_ticks}" "${corpus_id} candidate decisions"

    for check in "${approval_checks[@]}"; do
      require_boolean_value "${report}" "${prefix}.checks.${check}" "${corpus_id} ${check}"
      value="${REPLY}"
      if [[ "${decision}" == "approved" && "${value}" != "true" ]]; then
        fail "approved replay comparison requires ${prefix}.checks.${check}=true."
      fi
    done
    index="$(( index + 1 ))"
  done

  for tag in "${required_coverage[@]}"; do
    if [[ -z "${seen_coverage[${tag}]:-}" ]]; then
      fail "replay comparison is missing representative corpus coverage: ${tag}."
    fi
  done
}

validate_external_failover "${external_failover_path}"
validate_latency_lipsync "${latency_lipsync_path}"
validate_runtime_resilience "${runtime_resilience_path}"
validate_replay_comparison "${replay_comparison_path}"

print "Production evidence verified: external failover, latency/lip-sync, runtime resilience, and replay comparison."
