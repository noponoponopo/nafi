import Foundation

#if canImport(Carbon)
import Carbon

@MainActor
final class GlobalHotKeyService {
  static let shared = GlobalHotKeyService()

  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var action: (() -> Void)?

  private init() {}

  func configure(enabled: Bool, action: @escaping () -> Void) {
    unregister()
    self.action = action
    guard enabled else { return }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in service.action?() }
        return noErr
      },
      1,
      &eventType,
      pointer,
      &eventHandler
    )

    let identifier = EventHotKeyID(signature: OSType(0x4E_41_46_49), id: 1) // NAFI
    RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(cmdKey | optionKey),
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
  }

  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let eventHandler { RemoveEventHandler(eventHandler) }
    hotKey = nil
    eventHandler = nil
  }

}
#else
@MainActor
final class GlobalHotKeyService {
  static let shared = GlobalHotKeyService()
  private init() {}
  func configure(enabled: Bool, action: @escaping () -> Void) {}
  func unregister() {}
}
#endif
