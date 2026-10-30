import SharedKit

actor OfflineRPCDispatch: RPCDispatch {
    private var target: (any RPCDispatch)?

    func install(_ target: any RPCDispatch) {
        self.target = target
    }

    func removeTarget() {
        target = nil
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        guard let target else {
            throw CmuxRemoteRPCError.rpc(code: CmuxRemoteRPCError.notConnectedCode, message: "Not connected to the Mac relay yet")
        }
        return try await target.call(method: method, params: params)
    }
}
