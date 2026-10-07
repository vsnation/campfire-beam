// Filled in by tools/build.mjs. In an unbuilt tree (serving src/) the
// placeholders stay, BUILT is false and no service worker is registered.
export const APP_VERSION = '__BUILD_VERSION__';
export const BUILT = APP_VERSION !== '__BUILD' + '_VERSION__';
export const ENGINE_LOCK = /*__ENGINE_LOCK__*/ null;
export const RELEASE_PUBLIC_JWK = /*__RELEASE_PUBLIC_JWK__*/ null;
// The service worker's content-addressed file name (sw-<sha256 prefix>.js). Its
// bytes never change under that name, so a change there is a warning sign.
export const LOADER = '__LOADER__';
