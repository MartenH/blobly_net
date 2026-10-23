module transport

// wsl_distros is empty here: WSL distributions are something a Windows host has.
pub fn wsl_distros() []string {
	return []
}

// bridge_start_refusal is why bridge_start does nothing here: a bridge is started from Windows
// into WSL.
fn bridge_start_refusal() ?string {
	return 'starting a bridge in WSL is something the Windows build does; on Linux, use the CAN interface directly, or run canbridge yourself'
}

// bridge_program_dirs is empty here: nothing starts a bridge from this platform.
fn bridge_program_dirs() []string {
	return []
}

// bridge_launch_wsl is Windows-only; elsewhere a bridge is started by hand with the port and
// token `bridge_listen` returns.
fn bridge_launch_wsl(_ string, _ BridgeEndpoint) ! {
	return error(bridge_start_refusal() or { '' })
}
