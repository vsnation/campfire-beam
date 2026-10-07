// Campfire for BEAM: stand-in for package:camera_linux (see pubspec.yaml).
// Same API as the calls the QR dialog makes; no native code.

/// No camera on Linux in this build.
class CameraLinux {
  Future<void> initializeCamera() async =>
      throw UnsupportedError('No camera support on Linux in this build');

  void stopCamera() {}

  Future<String> captureImage() async =>
      throw UnsupportedError('No camera support on Linux in this build');
}
