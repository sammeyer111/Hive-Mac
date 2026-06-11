import Foundation
import HiveEngine

/// Re-establishes a dropped match. Both sides derive the same private room
/// code from the original session tokens, meet on the rendezvous again,
/// hole-punch a fresh channel, and the host re-syncs the authoritative game
/// state. The match continues where it left off.
@MainActor
enum ResumeCoordinator {

    static func attempt(match: MatchSession) async -> Bool {
        guard match.canReconnect else { return false }
        let code = GameCrypto.roomCode(fromKey: match.resumeKey)
        let isHost = match.isHost
        netlog("resume: attempting code \(code) as \(isHost ? "host" : "joiner")")

        guard let local = await PunchSetup.prepare() else { return false }
        let rendezvous = Rendezvous()
        guard await rendezvous.connect(will: isHost ? Rendezvous.hostTopic(code) : nil) else {
            local.socket.shutdown()
            return false
        }

        let myOffer = Rendezvous.Offer(
            endpoints: local.endpoints, name: match.myProfile.name, token: local.token)

        return await withCheckedContinuation { continuation in
            let done = Locked(false)
            var channel: UDPChannel?

            // All callbacks below arrive on the main queue; hop onto the
            // main actor explicitly so cleanup can touch the rendezvous.
            func finish(_ ok: Bool) {
                guard done.swap(true) == false else { return }
                Task { @MainActor in
                    if isHost { rendezvous.clearHostOffer(code: code) }
                    rendezvous.close()
                    if !ok {
                        if let channel {
                            channel.close()
                        } else {
                            local.socket.shutdown()
                        }
                    }
                    netlog("resume: \(ok ? "succeeded" : "failed")")
                    continuation.resume(returning: ok)
                }
            }

            rendezvous.onPeerOffer = { offer in
                guard channel == nil else { return }
                let key = GameCrypto.sessionKey(
                    hostToken: isHost ? local.token : offer.token,
                    joinerToken: isHost ? offer.token : local.token)
                let newChannel = UDPChannel(
                    socket: local.socket, candidates: offer.endpoints, sessionKey: key)
                channel = newChannel
                if isHost {
                    newChannel.onReady = { [weak newChannel] in
                        Task { @MainActor in
                            guard let newChannel else { return }
                            match.resume(channel: newChannel, syncedState: nil)
                            newChannel.send(.resumeState(match.game))
                            finish(true)
                        }
                    }
                } else {
                    Task { @MainActor in
                        rendezvous.publishJoinerAnswer(code: code, offer: myOffer)
                    }
                    newChannel.onMessage = { [weak newChannel] message in
                        guard case .resumeState(let state) = message else { return }
                        Task { @MainActor in
                            guard let newChannel else { return }
                            match.resume(channel: newChannel, syncedState: state)
                            finish(true)
                        }
                    }
                }
                newChannel.onClosed = { _ in finish(false) }
                newChannel.start()
            }

            if isHost {
                rendezvous.publishHostOffer(code: code, offer: myOffer)
            } else {
                rendezvous.lookupHost(code: code)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { finish(false) }
        }
    }
}
