//
//  SwiftAsyncUDPSocket+Connect.swift
//  SwiftAsyncSocket
//
//  Created by Di on 2019/1/15.
//  Copyright © 2019 chouheiwa. All rights reserved.
//

import Foundation

extension SwiftAsyncUDPSocket {

    func preConnect() throws {
        try preOpen()

        guard flags.contains(.connecting) || flags.contains(.didConnect) else {
            throw SwiftAsyncSocketError.badConfig(msg:
                "Cannot connect a socket more than once.")
        }

        guard isIPv6Enable || isIPv4Enable else {
            throw SwiftAsyncSocketError.badConfig(msg:
                "Both IPv4 and IPv6 have been disabled. " +
                "Must enable at least one protocol first.")
        }
    }

    public func connect(to host: String, port: UInt16) throws {
        var err: SwiftAsyncSocketError?

        socketQueueDo {
            do {
                try self.connectPreJob(prepareBlock: { (packet) in
                    packet.resolveInProgress = true

                    self.asyncResolved(host: host, port: port, completionBlock: {
                        packet.resolveInProgress = false
                        packet.resolvedAddresses = $0
                        packet.resolvedError = $1

                        self.maybeConnect()
                    })
                })
            } catch let error as SwiftAsyncSocketError {
                err = error
            } catch {
                fatalError("\(error)")
            }
        }

        if let error = err {
            throw error
        }
    }

    public func connect(to address: Data) throws {
        var err: SwiftAsyncSocketError?

        socketQueueDo {
            do {
                try self.connectPreJob(prepareBlock: { (packet) in
                    packet.resolvedAddresses = try? SocketDataType(data: address)
                })
            } catch let error as SwiftAsyncSocketError {
                err = error
            } catch {
                fatalError("\(error)")
            }
        }

        if let error = err {
            throw error
        }
    }

    func connectPreJob(prepareBlock: (SwiftAsyncUDPSpecialPacket) -> Void) throws {
        try self.preConnect()

        if !self.flags.contains(.didCreatSockets) {
            try self.createSocket(IPv4: self.isIPv4Enable, IPv6: self.isIPv6Enable)
        }

        let packet = SwiftAsyncUDPSpecialPacket()

        prepareBlock(packet)

        self.flags.insert(.connecting)

        self.sendQueue.append(packet)

        self.maybeDequeueSend()
    }

    func maybeConnect() {
        assert(DispatchQueue.getSpecific(key: queueKey) != nil, "Must be dispatched on socketQueue")

        guard let currentSend = currentSend as? SwiftAsyncUDPSpecialPacket else { return }

        guard !currentSend.resolveInProgress else {
            return
        }

        if currentSend.resolvedError != nil {
            delegateQueue?.async {
                self.delegate?.updSocket(self, didNotConnect: currentSend.resolvedError)
            }
        } else {
            guard let address = currentSend.resolvedAddresses else {
                assert(false, "Logic error")
                return
            }

            do {
                let data = try get(from: address)

                try connect(address: data)

                cachedConnectedAddress = data

                delegateQueue?.async {
                    self.delegate?.updSocket(self, didConnectTo: data)
                }
            } catch let error as SwiftAsyncSocketError {
                delegateQueue?.async {
                    self.delegate?.updSocket(self, didNotConnect: error)
                }
            } catch {
                fatalError("\(error)")
            }

        }

        flags.remove(.connecting)

        endCurrentSend()

        maybeDequeueSend()

    }

    private func connect(address: SwiftAsyncUDPSocketAddress) throws {
        assert(DispatchQueue.getSpecific(key: queueKey) != nil, "Must be dispatched on socketQueue")

        var function = self.closeSocket6
        var socketFD = socket4FD
        var insertFlag = SwiftAsyncUdpSocketFlags.IPv6Deactivated
        switch address.type {
        case .socket6:
            function = self.closeSocket4
            socketFD = socket6FD
            insertFlag = .IPv4Deactivated
        case .socket4:
            break
        }

        let status = Darwin.connect(socketFD,
                                    address.address.convert(),
                                    socklen_t(address.address.count))

        guard status == 0 else {
            throw SwiftAsyncSocketError.errno(code: errno,
                                              reason: "Error in connect() function")
        }

        function()
        flags.insert(insertFlag)
    }
}
