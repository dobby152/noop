import Foundation

extension AppModel {
    /// Spustí odesílání na vlastní přijímač (jen když je zapnuté). Běží mimo synchronizaci s páskem.
    func triggerSelfHostedPush() {
        guard SelfHostedPushSettings.enabled else { return }
        Task { [repo] in
            guard let store = await repo.storeHandle() else { return }
            SelfHostedPush.shared.trigger(store: store)
        }
    }
}
