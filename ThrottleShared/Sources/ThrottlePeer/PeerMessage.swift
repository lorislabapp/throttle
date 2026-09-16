import ThrottlePeerProtocol

/// Source compatibility for clients that import the product transport module.
/// The canonical framing contract lives in the standalone protocol package.
public typealias PeerMessage = ThrottlePeerProtocol.PeerMessage
