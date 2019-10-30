//
//  SocketManager.swift
//  Test_Socket
//
//  Created by Max on 2019/10/17.
//  Copyright © 2019 Max. All rights reserved.
//

import UIKit
import CoreFoundation

enum SocketState {
    case None
    case Creating
    case Connecting
    case Connected
    case Closing
    case Closed
}

// MARK: Error
enum SSError: Error {
    
    case Create(errno:Int32,des:String?=nil)
    case Connect(errno:Int32)
    case Read(errno:Int32)
    case Send(errno:Int32)
    case Stream(_:String)
    
    var localizedDescription: String {
        
        switch self {
        case .Create(let errno,let des):
            if let str = des {
                return str
            }else{
                return "create socket failed\(errno)"
            }
            
        case .Connect(let errno):
            return "failed on connect().errno:\(errno)"
        case .Read(let errno):
            return "failed on read().errno:\(errno)"
        case .Send(let errno):
            return "failed on send().errno:\(errno)"
        case .Stream(let des):
            return "stream error with description:\(des)"
        }
    }
}

// MARK: Socket Delegate
protocol SocketDelegate {
    
    func stateChanged(_ state:SocketState)
    func errorOccurred(_ error:SSError, atState:SocketState)
    func didRecv(_ data:Data)
    func didSend(_ count:Int)
}

class SocketSession: NSObject {
    
    var ip: String
    var port: UInt16
    var ai_family = AF_INET
    var bufferSize = 1024*64
    var delegate: SocketDelegate
    
    init(_ ip:String, port:UInt16, delegate:SocketDelegate) {
        self.ip = ip
        self.port = port
        self.delegate = delegate
    }
    
    var state = SocketState.None {
        didSet{
            DispatchQueue.main.async {
                self.delegate.stateChanged(self.state)
            }
        }
    }
    var writebuffer = Data()
    var sessionQueue = DispatchQueue(label: "sock_session")
    var readStream: InputStream?
    var writeStream: OutputStream?
    var streamThread: Thread?
    
    lazy var clientSocket: Int32 = { socket(ai_family, SOCK_STREAM, 0) }()
    
    lazy var adrInfo: sockaddr_in = {
        var adr = sockaddr_in()
        adr.sin_family = sa_family_t(ai_family)
        adr.sin_port = CFSwapInt16(port)
        adr.sin_addr.s_addr = inet_addr(ip)
        return adr;
    }()
    
    func connect(_ timeout:TimeInterval){
        
        if state == .None {
            state = .Creating
        } else {
            assert(false, "Session is already started")
            return
        }
        
        if clientSocket < 0 {
            DispatchQueue.main.async {
                self.delegate.errorOccurred(SSError.Create(errno: errno), atState: .Creating)
            }
            return
        }else{
            state = .Connecting
        }
        
        if timeout > 3 {
            DispatchQueue.main.asyncAfter(deadline: .now()+timeout) {
                if self.state == .Connecting {
                    self.delegate.errorOccurred(SSError.Create(errno: errno, des:"connect time out"), atState: self.state)
                    self.close()
                }
            }
        }
        
        print("Dlog]: connecting: \(ip):\(port)....")
        
        sessionQueue.async {
            withUnsafePointer(to: self.adrInfo, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    let result = Darwin.connect(self.clientSocket, $0, socklen_t(MemoryLayout.size(ofValue: self.adrInfo)))
                    if result == 0 {
                        self.didConnected()
                    }else{
                        perror("connect")
                        self.close()
                        DispatchQueue.main.async {
                            self.delegate.errorOccurred(SSError.Connect(errno: errno), atState: self.state)
                        }
                    }
                }
            })
        }
    }
    
    
    fileprivate func didConnected(){
        
        if self.state == .Connecting {
            if createStreams() {
                print("Dlog]: stream created")
                addToRunloop()
                state = .Connected
            } else {
                DispatchQueue.main.async {
                    self.delegate.errorOccurred(SSError.Stream("onCreate"), atState: self.state)
                }
            }
        }
    }
    
    fileprivate func addToRunloop(){
        
        streamThread = Thread {[weak self] in
            
            self?.readStream?.delegate = self
            self?.writeStream?.delegate = self
            self?.readStream?.schedule(in: .current, forMode: .common)
            self?.writeStream?.schedule(in: .current, forMode: .common)
            self?.readStream?.open()
            self?.writeStream?.open()
            RunLoop.current.run()
            print("Dlog]: stream schedule in runloop")
        }
        streamThread?.start()
    }
    
    fileprivate func createStreams() -> Bool {
        
        let readStreamPointer = UnsafeMutablePointer<Unmanaged<CFReadStream>?>.allocate(capacity: 1)
        let writeStreamPointer = UnsafeMutablePointer<Unmanaged<CFWriteStream>?>.allocate(capacity: 1)
        
        CFStreamCreatePairWithSocket(nil, clientSocket, readStreamPointer, writeStreamPointer)
        
        readStream = readStreamPointer.pointee?.takeRetainedValue() as InputStream?
        writeStream = writeStreamPointer.pointee?.takeRetainedValue() as OutputStream?
        
        if readStream == nil || writeStream == nil {
            readStream?.close()
            writeStream?.close()
            print("error in create stream")
            return false
        }
        
        readStream?.setProperty(kCFBooleanFalse, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        writeStream?.setProperty(kCFBooleanFalse, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        
        readStreamPointer.deallocate()
        writeStreamPointer.deallocate()
        return true
    }
}

// MARK: Read && Write
extension SocketSession: StreamDelegate {
    
    func send(_ body:Data)
    {
        if body.count > 0 {
            self.writebuffer.append(body)
        }
        self.write()
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        
        switch eventCode {
            
        case .openCompleted:
            print("Stream.Event openCompleted")
        case .hasBytesAvailable:
            print("Stream.Event hasBytesAvailable")
            read()
        case .hasSpaceAvailable:
            print("Stream.Event hasSpaceAvailable")
            write()
        case .errorOccurred:
            DispatchQueue.main.async {
                self.delegate.errorOccurred(SSError.Stream("Stream.Event return errorOccurred"), atState: self.state)
            }
            close()
            print("Stream.Event errorOccurred")
        case .endEncountered:
            print("Stream.Event endEncountered")
        default:
            break
        }
    }
    
    fileprivate func read(){
        
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let res = readStream?.read(&buffer, maxLength: bufferSize)
        
        if let count = res , count > 0 {
            var data = Data()
            data.append(&buffer, count: count)
            DispatchQueue.main.async {
                self.delegate.didRecv(data)
            }
        }
    }
    
    fileprivate func write(){
        
        sessionQueue.async {
            
            if let canWrite = self.writeStream?.hasSpaceAvailable, canWrite == true, self.writebuffer.count > 0 {
                
                let bytes = [UInt8](self.writebuffer)
                if let len = self.writeStream?.write(bytes, maxLength: self.writebuffer.count) {
                    if (len > 0){
                        DispatchQueue.main.async {
                            self.delegate.didSend(len)
                        }
                        if len >= self.writebuffer.count {
                            self.writebuffer = Data()
                        }else{
                            self.writebuffer = Data(bytes: bytes.suffix(self.writebuffer.count-len), count: self.writebuffer.count-len)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.delegate.errorOccurred(SSError.Stream("error in write(), errno:\(errno)"), atState: self.state)
                        }
                    }
                }
            }
        }
    }
}


// MARK: Close
extension SocketSession {
    
    func close() {
        
        sessionQueue.async {
            self.state = .Closing
            Darwin.close(self.clientSocket)
            if self.streamThread != nil {
                self.perform(#selector(self.removeFromRunloop), on: self.streamThread!, with: nil, waitUntilDone: true)
                self.streamThread = nil
            }
            self.state = .Closed
        }
    }
    
    @objc fileprivate func removeFromRunloop(){
        self.writeStream?.close()
        self.readStream?.close()
        self.writeStream?.remove(from: .current, forMode: .common)
        self.readStream?.remove(from: .current, forMode: .common)
        self.writeStream = nil
        self.readStream = nil
    }
}

