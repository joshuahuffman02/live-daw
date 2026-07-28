#!/bin/zsh

production_fixture_add_reference() {
  local plist="$1"
  local prefix="$2"
  local path="$3"
  local sha256 byte_count
  sha256="$(/usr/bin/shasum -a 256 "${path}" | /usr/bin/awk '{print $1}')"
  byte_count="$(/usr/bin/stat -f '%z' "${path}")"
  /usr/bin/plutil -insert "${prefix}" -json '{}' "${plist}"
  /usr/bin/plutil -insert "${prefix}.path" -string "${path}" "${plist}"
  /usr/bin/plutil -insert "${prefix}.sha256" -string "${sha256}" "${plist}"
  /usr/bin/plutil -insert "${prefix}.bytes" -integer "${byte_count}" "${plist}"
}

production_fixture_base_report() {
  local plist="$1"
  local proof_type="$2"
  local manifest_sha="$3"
  /usr/bin/plutil -create xml1 "${plist}"
  /usr/bin/plutil -insert formatVersion -integer 1 "${plist}"
  /usr/bin/plutil -insert proofType -string "${proof_type}" "${plist}"
  /usr/bin/plutil -insert completedAtUTC -string 2026-07-28T00:00:00Z "${plist}"
  /usr/bin/plutil -insert venueRig -bool true "${plist}"
  /usr/bin/plutil -insert phase -string sermon "${plist}"
  /usr/bin/plutil -insert fullCheckManifestSHA256 -string "${manifest_sha}" "${plist}"
}

production_fixture_attachment() {
  local root="$1"
  local name="$2"
  local path="${root}/${name}"
  print -r -- "fixture ${name}" > "${path}"
  REPLY="${path}"
}

production_fixture_replay_metrics() {
  local path="$1"
  local crc="$2"
  /usr/bin/plutil -create xml1 "${path}"
  /usr/bin/plutil -insert schemaVersion -integer 2 "${path}"
  /usr/bin/plutil -insert input -string "/proof/service-001.wav" "${path}"
  /usr/bin/plutil -insert sourceCrc32 -string "${crc}" "${path}"
  /usr/bin/plutil -insert scene -string sermon "${path}"
  /usr/bin/plutil -insert roles -json '["speech"]' "${path}"
  /usr/bin/plutil -insert stereoPairs -json '[]' "${path}"
  /usr/bin/plutil -insert sampleRate -integer 96000 "${path}"
  /usr/bin/plutil -insert blockSize -integer 256 "${path}"
  /usr/bin/plutil -insert sourceChannels -integer 3 "${path}"
  /usr/bin/plutil -insert inputChannels -integer 1 "${path}"
  /usr/bin/plutil -insert frames -integer 28800000 "${path}"
  /usr/bin/plutil -insert durationSeconds -float 300.0 "${path}"
  /usr/bin/plutil -insert decisionTicks -integer 6000 "${path}"
  /usr/bin/plutil -insert targetLufs -float -16.0 "${path}"
  /usr/bin/plutil -insert outputSamplePeakDbfs -float -1.2 "${path}"
  /usr/bin/plutil -insert outputIntegratedLufs -float -16.2 "${path}"
  /usr/bin/plutil -insert outputShortTermLufs -float -15.8 "${path}"
  /usr/bin/plutil -insert maximumLimiterGainReductionDb -float 0.5 "${path}"
  /usr/bin/plutil -insert finalAutoLoudnessTrimDb -float 0.2 "${path}"
  /usr/bin/plutil -insert inputActive -bool true "${path}"
  /usr/bin/plutil -insert outputActive -bool true "${path}"
  /usr/bin/plutil -insert outputFinite -bool true "${path}"
  /usr/bin/plutil -insert referenceAvailable -bool true "${path}"
  /usr/bin/plutil -insert referenceIntegratedLufs -float -16.0 "${path}"
  /usr/bin/plutil -insert referenceDeltaLufs -float -0.2 "${path}"
  /usr/bin/plutil -insert safetyPassed -bool true "${path}"
  /usr/bin/plutil -convert json "${path}"
}

create_production_evidence_fixtures() {
  local root="$1"
  local plist json attachment id prefix
  local -a failover_tests runtime_tests
  /bin/mkdir -p "${root}"
  root="$(/bin/realpath "${root}")"
  typeset -gA production_evidence_paths
  typeset -gA production_evidence_attachments
  local manifest_sha

  production_fixture_attachment "${root}" full-check-manifest.json
  production_evidence_attachments[full-check-manifest]="${REPLY}"
  manifest_sha="$(/usr/bin/shasum -a 256 "${REPLY}" | /usr/bin/awk '{print $1}')"

  plist="${root}/external-failover.plist"
  json="${root}/external-failover.json"
  production_fixture_base_report "${plist}" external-failover "${manifest_sha}"
  /usr/bin/plutil -insert switchModel -string "Venue fail-safe A/B 1" "${plist}"
  /usr/bin/plutil -insert primaryEncoderInput -string "Encoder input A" "${plist}"
  /usr/bin/plutil -insert backupEncoderInput -string "Encoder input B" "${plist}"
  /usr/bin/plutil -insert heartbeatMechanism -string "Normally energized hardware GPIO and carrier detect" "${plist}"
  /usr/bin/plutil -insert backupIsDefaultState -bool true "${plist}"
  /usr/bin/plutil -insert manualReturnOnly -bool true "${plist}"
  /usr/bin/plutil -insert broadcastIsolationConfirmed -bool true "${plist}"
  /usr/bin/plutil -insert manualReturnVerified -bool true "${plist}"
  /usr/bin/plutil -insert truePeakCeilingDbTP -float -1.0 "${plist}"
  production_fixture_attachment "${root}" wiring-diagram.txt
  production_evidence_attachments[wiring-diagram]="${REPLY}"
  production_fixture_add_reference "${plist}" wiringDiagram "${REPLY}"
  /usr/bin/plutil -insert tests -json '[]' "${plist}"
  failover_tests=(
    force-quit-app
    stop-dvs-core-audio
    disconnect-dante-network
    remove-output-device
    power-off-mac
  )
  integer index=0
  for id in "${failover_tests[@]}"; do
    prefix="tests.${index}"
    /usr/bin/plutil -insert "${prefix}" -json '{}' "${plist}"
    /usr/bin/plutil -insert "${prefix}.id" -string "${id}" "${plist}"
    /usr/bin/plutil -insert "${prefix}.passed" -bool true "${plist}"
    /usr/bin/plutil -insert "${prefix}.programAudioPresent" -bool true "${plist}"
    /usr/bin/plutil -insert "${prefix}.bothEncoderInputsRecorded" -bool true "${plist}"
    /usr/bin/plutil -insert "${prefix}.selectedOutputRecorded" -bool true "${plist}"
    /usr/bin/plutil -insert "${prefix}.speechIntelligible" -bool true "${plist}"
    /usr/bin/plutil -insert "${prefix}.fohReturnLeakDetected" -bool false "${plist}"
    /usr/bin/plutil -insert "${prefix}.oscillationDetected" -bool false "${plist}"
    /usr/bin/plutil -insert "${prefix}.stateVisible" -bool true "${plist}"
    /usr/bin/plutil -insert "${prefix}.heldBackupUntilManualReturn" -bool true "${plist}"
    /usr/bin/plutil -insert "${prefix}.switchTimeSeconds" -float 1.2 "${plist}"
    /usr/bin/plutil -insert "${prefix}.maxSilentGapSeconds" -float 1.1 "${plist}"
    /usr/bin/plutil -insert "${prefix}.selectedOutputTruePeakDbTP" -float -1.3 "${plist}"
    production_fixture_attachment "${root}" "failover-${id}.wav"
    production_evidence_attachments["failover-${id}"]="${REPLY}"
    production_fixture_add_reference "${plist}" "${prefix}.recording" "${REPLY}"
    index="$(( index + 1 ))"
  done
  /usr/bin/plutil -convert json -o "${json}" "${plist}"
  /bin/rm "${plist}"
  production_evidence_paths[external-failover]="${json}"

  plist="${root}/latency-lipsync.plist"
  json="${root}/latency-lipsync.json"
  production_fixture_base_report "${plist}" latency-lipsync "${manifest_sha}"
  /usr/bin/plutil -insert productionRouteVerified -bool true "${plist}"
  /usr/bin/plutil -insert measurementMethod -string "Frame-accurate flash and beep at final encoder program" "${plist}"
  /usr/bin/plutil -insert warmupMinutes -integer 30 "${plist}"
  /usr/bin/plutil -insert sampleCount -integer 10 "${plist}"
  /usr/bin/plutil -insert audioPathMedianMs -float 120.0 "${plist}"
  /usr/bin/plutil -insert videoPathMedianMs -float 165.0 "${plist}"
  /usr/bin/plutil -insert compensation -json '{}' "${plist}"
  /usr/bin/plutil -insert compensation.target -string audio "${plist}"
  /usr/bin/plutil -insert compensation.delayMs -float 45.0 "${plist}"
  /usr/bin/plutil -insert venueAcceptanceLimitMs -float 20.0 "${plist}"
  /usr/bin/plutil -insert residualMedianOffsetMs -float 8.0 "${plist}"
  /usr/bin/plutil -insert clockTopology -string "HD96 PTP leader; DVS and encoder output share Aggregate Device clock" "${plist}"
  /usr/bin/plutil -insert inputBufferFrames -integer 256 "${plist}"
  /usr/bin/plutil -insert outputBufferFrames -integer 256 "${plist}"
  /usr/bin/plutil -insert inputDeviceLatencyFrames -integer 128 "${plist}"
  /usr/bin/plutil -insert outputDeviceLatencyFrames -integer 128 "${plist}"
  /usr/bin/plutil -insert separateOutputPrebufferFrames -integer 512 "${plist}"
  /usr/bin/plutil -insert driftObservation -json '{}' "${plist}"
  /usr/bin/plutil -insert driftObservation.durationSeconds -integer 7200 "${plist}"
  /usr/bin/plutil -insert driftObservation.syncEventCount -integer 3 "${plist}"
  /usr/bin/plutil -insert driftObservation.offsetChangeMs -float 4.0 "${plist}"
  /usr/bin/plutil -insert driftObservation.msPerHour -float 2.0 "${plist}"
  /usr/bin/plutil -insert driftObservation.limitMsPerHour -float 5.0 "${plist}"
  /usr/bin/plutil -insert driftObservation.control -string aggregate-device-drift-correction "${plist}"
  /usr/bin/plutil -insert driftObservation.withinLimit -bool true "${plist}"
  production_fixture_attachment "${root}" latency-raw-measurements.csv
  production_evidence_attachments[latency-raw-measurements]="${REPLY}"
  production_fixture_add_reference "${plist}" rawMeasurements "${REPLY}"
  production_fixture_attachment "${root}" latency-test-recording.mov
  production_evidence_attachments[latency-test-recording]="${REPLY}"
  production_fixture_add_reference "${plist}" testRecording "${REPLY}"
  /usr/bin/plutil -convert json -o "${json}" "${plist}"
  /bin/rm "${plist}"
  production_evidence_paths[latency-lipsync]="${json}"

  plist="${root}/runtime-resilience.plist"
  json="${root}/runtime-resilience.json"
  production_fixture_base_report "${plist}" runtime-resilience "${manifest_sha}"
  /usr/bin/plutil -insert tests -json '[]' "${plist}"
  runtime_tests=(
    callback-stall-recovery
    output-device-reattach
    recording-resume
    encoder-egress-alerts
    launchagent-relaunch
    operator-stop-no-restart
    external-failover-handoff
  )
  index=0
  for id in "${runtime_tests[@]}"; do
    prefix="tests.${index}"
    /usr/bin/plutil -insert "${prefix}" -json '{}' "${plist}"
    /usr/bin/plutil -insert "${prefix}.id" -string "${id}" "${plist}"
    /usr/bin/plutil -insert "${prefix}.passed" -bool true "${plist}"
    case "${id}" in
      callback-stall-recovery)
        /usr/bin/plutil -insert "${prefix}.unhealthyGraceSeconds" -float 2.0 "${plist}"
        /usr/bin/plutil -insert "${prefix}.engineRestarted" -bool true "${plist}"
        ;;
      output-device-reattach)
        /usr/bin/plutil -insert "${prefix}.boundedBackoffObserved" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.routeRecovered" -bool true "${plist}"
        ;;
      recording-resume)
        /usr/bin/plutil -insert "${prefix}.newRecordingDirectoryCreated" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.wavHeadersValid" -bool true "${plist}"
        ;;
      encoder-egress-alerts)
        /usr/bin/plutil -insert "${prefix}.staleResponseRejected" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.unhealthyResponseRejected" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.desktopCriticalAlertObserved" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.remoteCriticalAlertObserved" -bool true "${plist}"
        ;;
      launchagent-relaunch)
        /usr/bin/plutil -insert "${prefix}.applicationRelaunched" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.sessionResumed" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.captureResumed" -bool true "${plist}"
        ;;
      operator-stop-no-restart)
        /usr/bin/plutil -insert "${prefix}.recoveryDisarmed" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.automaticRestartObserved" -bool false "${plist}"
        ;;
      external-failover-handoff)
        /usr/bin/plutil -insert "${prefix}.allKillTestsPassed" -bool true "${plist}"
        /usr/bin/plutil -insert "${prefix}.heldBackupUntilManualReturn" -bool true "${plist}"
        ;;
    esac
    production_fixture_attachment "${root}" "runtime-${id}.txt"
    production_evidence_attachments["runtime-${id}"]="${REPLY}"
    production_fixture_add_reference "${plist}" "${prefix}.evidence" "${REPLY}"
    index="$(( index + 1 ))"
  done
  /usr/bin/plutil -convert json -o "${json}" "${plist}"
  /bin/rm "${plist}"
  production_evidence_paths[runtime-resilience]="${json}"

  plist="${root}/replay-comparison.plist"
  json="${root}/replay-comparison.json"
  production_fixture_base_report "${plist}" replay-comparison "${manifest_sha}"
  /usr/bin/plutil -insert reviewer -string "Fixture Reviewer" "${plist}"
  /usr/bin/plutil -insert findings -string "No blocking electrical or artistic regression in the complete blind review." "${plist}"
  /usr/bin/plutil -insert decision -string approved "${plist}"
  /usr/bin/plutil -insert blindListeningCompleted -bool true "${plist}"
  /usr/bin/plutil -insert baselineCommit -string fedcba9876543210fedcba9876543210fedcba98 "${plist}"
  /usr/bin/plutil -insert candidateCommit -string 0123456789abcdef0123456789abcdef01234567 "${plist}"
  /usr/bin/plutil -insert comparisons -json '[]' "${plist}"
  /usr/bin/plutil -insert comparisons.0 -json '{}' "${plist}"
  /usr/bin/plutil -insert comparisons.0.corpusID -string service-001 "${plist}"
  /usr/bin/plutil -insert comparisons.0.completeServiceReviewed -bool true "${plist}"
  /usr/bin/plutil -insert comparisons.0.coverageTags -json \
    '["sermon","prayer","walk-in-out-playback","quiet-speaker","loud-speaker","panel-handoff","intentional-silence","feedback-noise","missing-channel","repatched-role"]' \
    "${plist}"
  /usr/bin/plutil -insert comparisons.0.baselineSourceCRC32 -string 89abcdef "${plist}"
  /usr/bin/plutil -insert comparisons.0.candidateSourceCRC32 -string 89abcdef "${plist}"
  /usr/bin/plutil -insert comparisons.0.baseline -json '{}' "${plist}"
  /usr/bin/plutil -insert comparisons.0.candidate -json '{}' "${plist}"
  /usr/bin/plutil -insert comparisons.0.checks -json '{}' "${plist}"
  for id in \
    finiteOutput \
    noUnexpectedSilence \
    noClippingRegression \
    noSustainedLimiterReduction \
    noUnexplainedDecisionJumps \
    loudnessWithinTolerance \
    blindListeningPassed; do
    /usr/bin/plutil -insert "comparisons.0.checks.${id}" -bool true "${plist}"
  done
  production_fixture_attachment "${root}" replay-baseline-program.wav
  production_evidence_attachments[replay-baseline-program]="${REPLY}"
  production_fixture_add_reference "${plist}" comparisons.0.baseline.program "${REPLY}"
  attachment="${root}/replay-baseline-metrics.json"
  production_fixture_replay_metrics "${attachment}" 89abcdef
  production_evidence_attachments[replay-baseline-metrics]="${attachment}"
  production_fixture_add_reference "${plist}" comparisons.0.baseline.metrics "${attachment}"
  attachment="${root}/replay-baseline-decisions.jsonl"
  /usr/bin/awk 'BEGIN { for (tick = 0; tick < 6000; ++tick) print "{\"tick\":" tick "}" }' \
    > "${attachment}"
  production_evidence_attachments[replay-baseline-decisions]="${attachment}"
  production_fixture_add_reference "${plist}" comparisons.0.baseline.decisions "${attachment}"
  production_fixture_attachment "${root}" replay-candidate-program.wav
  production_evidence_attachments[replay-candidate-program]="${REPLY}"
  production_fixture_add_reference "${plist}" comparisons.0.candidate.program "${REPLY}"
  attachment="${root}/replay-candidate-metrics.json"
  production_fixture_replay_metrics "${attachment}" 89abcdef
  production_evidence_attachments[replay-candidate-metrics]="${attachment}"
  production_fixture_add_reference "${plist}" comparisons.0.candidate.metrics "${attachment}"
  attachment="${root}/replay-candidate-decisions.jsonl"
  /usr/bin/awk 'BEGIN { for (tick = 0; tick < 6000; ++tick) print "{\"tick\":" tick "}" }' \
    > "${attachment}"
  production_evidence_attachments[replay-candidate-decisions]="${attachment}"
  production_fixture_add_reference "${plist}" comparisons.0.candidate.decisions "${attachment}"
  production_fixture_attachment "${root}" replay-reference-mix.wav
  production_evidence_attachments[replay-reference-mix]="${REPLY}"
  production_fixture_add_reference "${plist}" comparisons.0.referenceMix "${REPLY}"
  /usr/bin/plutil -convert json -o "${json}" "${plist}"
  /bin/rm "${plist}"
  production_evidence_paths[replay-comparison]="${json}"
}
