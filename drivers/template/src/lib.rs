use std::ffi::{c_char, c_void};

const DBZ_DRIVER_ABI_VERSION: u32 = 1;
static DRIVER_NAME: &[u8] = b"template\0";

#[no_mangle]
pub extern "C" fn dbz_driver_abi_version() -> u32 {
    DBZ_DRIVER_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn dbz_driver_name() -> *const c_char {
    DRIVER_NAME.as_ptr().cast()
}

#[no_mangle]
pub unsafe extern "C" fn dbz_driver_open(
    _connection_id: u64,
    _dsn: *const c_char,
) -> *mut c_void {
    std::ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn dbz_driver_close(_handle: *mut c_void) {}
