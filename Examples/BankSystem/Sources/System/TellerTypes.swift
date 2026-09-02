import Teller

// `Teller` is both the module and, in Ledger, `typealias Teller = String`,
// so `Teller.Req` does not name the module's type once both are imported.
// This file imports the teller alone and names its wire types.
public typealias TellerReq = Req
public typealias TellerRep = Rep
public typealias TellerId = Id
public typealias TellerRequest = Request
public typealias TellerReply = Reply
