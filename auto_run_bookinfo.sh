#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TARGET_SCRIPT="./run_new_bookinfo.sh"
CASE_STATUS_LOG="auto_run_case_status.log"

if [[ ! -x "${TARGET_SCRIPT}" ]]; then
  if [[ -f "${TARGET_SCRIPT}" ]]; then
    chmod +x "${TARGET_SCRIPT}"
  else
    echo "ERROR: ${TARGET_SCRIPT} not found in ${SCRIPT_DIR}"
    exit 1
  fi
fi


pods_list=(5 10 15 20)
schedulers=(def qos)


qpss=(5 10 15 20)

total_cases=$(( ${#pods_list[@]} * ${#schedulers[@]} * ${#qpss[@]} ))
case_no=0
failed_cases=()

log_case_status() {
  local status="$1"
  local scheduler="$2"
  local pods="$3"
  local qps="$4"
  local case_no="$5"
  local ts
  ts="$(date --iso-8601=seconds)"
  echo "${ts},${pods},${qps},${scheduler},${status},${case_no}" >> "${CASE_STATUS_LOG}"
}



for repeat in {1..1}; do
  echo "#########################"
  echo "Repeat: ${repeat}/5"
  echo "#########################"
for pods in "${pods_list[@]}"; do
  for scheduler in "${schedulers[@]}"; do
    for qps in "${qpss[@]}"; do
      case_no=$((case_no + 1))

      echo "============================================================"
      echo "Running case ${case_no}/${total_cases}"
      echo "Scheduler: ${scheduler}"
      echo "Pods: ${pods}"
      echo "QPS: ${qps}"
      echo "============================================================"
      kubectl delete pod -n he-codeco-swm $(kubectl get pod -n he-codeco-swm --no-headers | awk '{print $1}')
      echo "SWM has been restarted"
      sleep 15
      if "${TARGET_SCRIPT}" "${scheduler}" "${pods}" "${qps}" "${case_no}"; then
        echo "OK: scheduler=${scheduler}, pods=${pods}, qps=${qps}"
        log_case_status "OK" "${scheduler}" "${pods}" "${qps}" "${case_no}"
	echo "wait for 60 sec between 2 exp"
	kubectl delete namespace kdh --ignore-not-found=true >/dev/null 2>&1 || true
		
      else
        rc=$?
        log_case_status "ERROR" "${scheduler}" "${pods}" "${qps}" "${case_no}"
        failed_cases+=("case=${case_no} scheduler=${scheduler} pods=${pods} qps=${qps} exit_code=${rc}")
        kubectl delete namespace kdh --ignore-not-found=true >/dev/null 2>&1 || true
	sleep 10
      fi
    done
  done
done
done

if [[ ${#failed_cases[@]} -eq 0 ]]; then
  echo "No errors. All ${total_cases} cases completed successfully."
else
  echo "Errors (${#failed_cases[@]} case(s)):"
  for err in "${failed_cases[@]}"; do
    echo "${err}"
  done
fi
