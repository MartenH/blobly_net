module telem

// EthWatch identifies one plotted eth event field — the Graphics analogue of a
// DBC signal watch. It carries a SNAPSHOT of the manifest layout row so the
// per-sample decode never chases a reloading manifest; reconcile_eth_watches
// refreshes or drops the snapshot on a project rebuild.
pub struct EthWatch {
pub:
	id  u16      // SOME/IP event id (the trace row id)
	ch  string   // the someip channel name (trace `ch`) — gates row sampling
	fld EthField // layout snapshot: offset/width/type + frame/field names
}

// sample decodes this field from an event payload as an f64 plot sample (the
// raw integer value — eth fields are unscaled by design; conditioning is app
// work). Unsigned types go through u64 so a value above i64 max plots
// positive; values beyond 2^53 lose low bits to the f64 mantissa, which is
// inherent to plotting, not to this conversion.
pub fn (w EthWatch) sample(payload []u8) ?f64 {
	v := w.fld.decode(payload)?
	if w.fld.typ.starts_with('i') {
		return f64(v)
	}
	return f64(u64(v))
}

// reconcile_eth_watches re-resolves eth watches against THIS (rebuilt)
// manifest: a watch whose event id or field name no longer resolves is
// dropped. DBC watches survive a rebuild because their decode fails closed
// through the live DBC lookup — an eth watch decodes by snapshot offsets, and
// a stale layout would decode garbage instead, so stale ones must go.
// Survivors get a fresh snapshot and the current someip channel name; ch ==
// '' (no someip channel in the rebuilt project) drops them all.
pub fn (m &Manifest) reconcile_eth_watches(ws []EthWatch, ch string) []EthWatch {
	if ch == '' {
		return []
	}
	mut kept := []EthWatch{cap: ws.len}
	for w in ws {
		f := m.eth_frame_by_id(w.id) or { continue }
		for fld in m.eth_fields(f.name) {
			if fld.field == w.fld.field {
				kept << EthWatch{w.id, ch, fld}
				break
			}
		}
	}
	return kept
}
