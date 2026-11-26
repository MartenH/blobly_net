module transport

// sjw_rule is one phase's resynchronisation jump width: the most the rule allows,
// min(tseg1, tseg2), held to the phase's register ceiling. A resynchronisation may lengthen
// phase 1 or shorten phase 2 by at most the SJW, so neither segment may be shorter than it.
//
// It is the ONE copy of the rule: the CANsub's solver (cansub_timing.v), PCAN's FD string
// (pcan_names.v) and Vector's FD phases (vector_segments) all ask it, each with its own ceiling.
// A classic Vector port is the one exception, min(tseg2, 4), what XLchipParams' register holds.
//
// Why not a fixed count: a fixed 4 quanta, the vendor tables' value, shrinks as a fraction of the
// bit as the quanta per bit grow — at 500 kbit/s the CANsub and PCAN solvers take 160 quanta,
// where 4 is 2.5% of a bit, too little to follow the other nodes' edges. Measured on a CANsub.4
// (02.05.00) beside two STM32 FDCANs, receiving only: 20 controller errors a minute at SJW 4,
// none at SJW 32 (= seg2), over the same traffic (#359).
fn sjw_rule(tseg1 int, tseg2 int, ceiling int) int {
	mut sjw := if tseg1 < tseg2 { tseg1 } else { tseg2 }
	if sjw > ceiling {
		sjw = ceiling
	}
	return sjw
}
