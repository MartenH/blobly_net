// project — a project's `lin:` bus as a Row is started with: the one translation the headless run
// and the GUI both start their rows by.
module lin

import blobly.project

// spec_of is a project's LIN bus as a Row is started with, its LDF resolved against the project's
// directory as a database is.
pub fn spec_of(b project.LinBus, proj_dir string) RowSpec {
	return RowSpec{
		name:     b.name
		address:  b.address
		baud:     b.bitrate
		ldf:      if b.ldf == '' { '' } else { project.resolve_asset(proj_dir, b.ldf) }
		role:     match b.role {
			'master' { Role.master }
			'slave' { Role.slave }
			else { Role.monitor }
		}
		simulate: b.simulate
		schedule: b.schedule
	}
}
