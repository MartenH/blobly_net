module transport

// wsl_distros is empty here: WSL distributions are something a Windows host has.
pub fn wsl_distros() []string {
	return []
}

// bridge_launch_wsl is Windows-only; elsewhere a bridge is started by hand with the port and
// token `bridge_listen` returns.
fn bridge_launch_wsl(distro string, ep BridgeEndpoint) ! {
	return error('starting a bridge in WSL is something the Windows build does; run canbridge yourself')
}
