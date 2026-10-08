$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/runtime-environment.ps1"
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/cyclic_timing_reservation_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/cyclic_timing_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/cyclic_timing_native_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/input_path_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/cycle_conformance_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/startup_progress_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/startup_progress_native_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/utilization_policy_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/simulation_startup_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/simulation_startup_native_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/strict_gap_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/strict_gap_native_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/termination_modes_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/sixty_lot_responsiveness_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/optimizer_cancel_start_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/optimizer_settings_sequence_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/incremental_delivery_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/incremental_native_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/gap_history_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/gap_approximate_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/client_disconnect_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/dispatch_history_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/performance_implementation_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/cyclic_reuse_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/job_release_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/holding_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/runtests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/native_reuse_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/test/solver_gui_tests.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $bundledJulia --startup-file=no "--project=$PSScriptRoot" "$PSScriptRoot/vendor/JobShopSim/test/runtests.jl"
exit $LASTEXITCODE
