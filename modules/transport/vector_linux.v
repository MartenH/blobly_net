// The Linux half of vector_driver_status. There is no XL driver here — Vector ships vxlapi for
// Windows, and WSL cannot reach the Windows one — so the answer is fixed. It exists as a real
// function rather than a `$if` at the call site because the caller is asking about the machine,
// and every other backend answers that question from its own file.
module transport

// vector_driver_status: -1, the same code vector_windows.v returns for "vxlapi64.dll absent".
pub fn vector_driver_status() int {
	return -1
}
