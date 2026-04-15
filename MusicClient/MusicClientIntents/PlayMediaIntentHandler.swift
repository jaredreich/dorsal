// Handles INPlayMediaIntent from Siri

import Intents

class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let response = INPlayMediaIntentResponse(code: .continueInApp, userActivity: nil)
        completion(response)
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        guard let mediaSearch = intent.mediaSearch else {
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        completion(SearchManager.shared.resolveMediaItems(from: mediaSearch))
    }
}
