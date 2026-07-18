//
//  VerificationPhrase.swift
//  Shared — AgentDeck
//
//  §13.2 human-readable verification: a 6-word phrase both devices derive
//  deterministically from SHA-256(serverPublicKey ‖ clientPublicKey ‖
//  server verificationCode). The phrase is the friendly check; the
//  fingerprint comparison is the primary cryptographic one. The 256-word
//  list is deliberately common, short, distinct words.
//

import CryptoKit
import Foundation

public enum VerificationPhrase {
    /// Word count in a phrase (§13.2: 6-word phrase).
    public static let phraseLength = 6

    /// Derives the phrase words. Both sides compute identical words from
    /// the same inputs — any MITM changes the inputs and thus the phrase.
    public static func words(
        serverPublicKey: Data,
        clientPublicKey: Data,
        verificationCode: Data
    ) -> [String] {
        var input = Data()
        input.append(serverPublicKey)
        input.append(clientPublicKey)
        input.append(verificationCode)
        let digest = SHA256.hash(data: input)
        return digest.prefix(phraseLength).map { wordList[Int($0)] }
    }

    /// Display form for the comparison screens.
    public static func display(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    /// 256 distinct common words. Tests pin count and uniqueness.
    static let wordList: [String] = [
        "anchor", "apple", "arrow", "atlas", "autumn", "avenue", "badge", "bamboo",
        "beacon", "bicycle", "birch", "blossom", "bottle", "breeze", "bridge", "bronze",
        "bubble", "bucket", "butter", "cabin", "cactus", "candle", "canoe", "canyon",
        "carpet", "castle", "cedar", "chalk", "chapel", "cherry", "circle", "citrus",
        "cliff", "clinic", "clock", "cloud", "clover", "cobalt", "coffee", "comet",
        "compass", "copper", "coral", "corner", "cotton", "cradle", "crater", "cricket",
        "crystal", "curtain", "dagger", "daisy", "dance", "dawn", "delta", "desert",
        "diamond", "dinner", "dolphin", "domino", "donkey", "dragon", "drawer", "drift",
        "dust", "eagle", "earth", "echo", "elbow", "ember", "engine", "estuary",
        "fabric", "falcon", "feather", "fiddle", "fig", "filter", "flame", "flint",
        "flower", "flute", "fog", "forest", "fountain", "fox", "frost", "galaxy",
        "garage", "garden", "garlic", "garnet", "gate", "gentle", "ginger", "glacier",
        "globe", "glove", "gold", "goose", "granite", "grape", "gravel", "green",
        "guitar", "harbor", "hawk", "hazel", "helmet", "heron", "hill", "honey",
        "horizon", "horse", "hotel", "house", "hunter", "ice", "igloo", "indigo",
        "inlet", "iron", "island", "ivory", "jacket", "jade", "jasmine", "jewel",
        "jungle", "juniper", "kayak", "kettle", "key", "kingdom", "kite", "kitten",
        "ladder", "lagoon", "lake", "lantern", "larch", "laser", "laurel", "leader",
        "leaf", "lemon", "lens", "letter", "lilac", "lily", "linen", "lion",
        "lizard", "lobster", "lodge", "lotus", "lunar", "magnet", "magnolia", "maple",
        "marble", "market", "meadow", "melody", "melon", "mercury", "metal", "midnight",
        "mill", "mirror", "mist", "mitten", "mole", "monkey", "moon", "mosaic",
        "moss", "motor", "mountain", "mouse", "mushroom", "music", "napkin", "needle",
        "nest", "nickel", "night", "noble", "north", "novel", "oak", "ocean",
        "olive", "onion", "opal", "orange", "orbit", "orchid", "otter", "owl",
        "oyster", "paddle", "palace", "palm", "panda", "paper", "parcel", "parrot",
        "pastel", "path", "peach", "pebble", "pelican", "pencil", "pepper", "petal",
        "piano", "picnic", "pigeon", "pilot", "pine", "planet", "plaza", "plum",
        "pocket", "polar", "pond", "poplar", "potato", "powder", "prairie", "prism",
        "pumpkin", "purple", "quartz", "rabbit", "radar", "rain", "rainbow", "ranch",
        "raven", "reed", "ribbon", "ridge", "river", "robin", "rocket", "rose",
        "ruby", "saddle", "salmon", "sand", "sapphire", "saturn", "scarlet", "school"
    ]
}
