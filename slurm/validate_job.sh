#!/bin/bash
#SBATCH --job-name=mmb-validate
#SBATCH --time=03:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --output=mmb-validate-%j.out
#SBATCH --error=mmb-validate-%j.err
# Submit with the account from config/cluster.sh:
#   . config/cluster.sh
#   sbatch --account="$MMB_ACCOUNT_CPU" slurm/validate_job.sh

# Run validateAllMMBTest over every dataset under the output root, using
# tests/run_validation.m as the driver.
#
# Outputs in <output root>/_validation/:
#   test_results_<jobid>.mat   MATLAB TestResult struct
#   summary-<jobid>.txt        pass/fail summary
#
# Slurm's own log files land in the submission directory as
# mmb-validate-<jobid>.out and .err.

set -euo pipefail

ROOT=$(cd "${SLURM_SUBMIT_DIR:-.}" && pwd)
. "$ROOT/config/cluster.sh"
case "$MMB_OUTPUT_ROOT" in
    /*) OUTROOT=$MMB_OUTPUT_ROOT ;;
    *)  OUTROOT=$ROOT/$MMB_OUTPUT_ROOT ;;
esac
export MMB_RUNS_OUTPUT="$OUTROOT"

VALIDATION_DIR="$OUTROOT/_validation"
mkdir -p "$VALIDATION_DIR"

JOBID="${SLURM_JOB_ID:-local-$(date +%s)}"
RESULTS_MAT="$VALIDATION_DIR/test_results_${JOBID}.mat"
SUMMARY_TXT="$VALIDATION_DIR/summary-${JOBID}.txt"

echo "=== MMB Validation Run ==="
echo "  Job ID:       $JOBID"
echo "  Started:      $(date)"
echo "  Working dir:  $(pwd)"
echo "  Driver:       tests/run_validation.m"
echo "  Results .mat: $RESULTS_MAT"
echo "  Summary .txt: $SUMMARY_TXT"
echo "  CPUs:         ${SLURM_CPUS_PER_TASK:-1}"
echo

module load $MMB_MODULES_MATLAB

addpath_cmd="addpath('tests')"
batch_cmd="${addpath_cmd}; exit(run_validation('${RESULTS_MAT}', '${SUMMARY_TXT}'))"

matlab -batch "$batch_cmd"
matlab_rc=$?

echo
echo "=== Finished: $(date) (matlab rc=$matlab_rc) ==="
exit $matlab_rc
