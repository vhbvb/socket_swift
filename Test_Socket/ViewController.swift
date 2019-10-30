//
//  ViewController.swift
//  Test_Socket
//
//  Created by Max on 2019/10/17.
//  Copyright © 2019 Max. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
    
    lazy var session = {
        SocketSession.init("172.25.49.121", port: 1314, delegate: self)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        let url = URL(string: "http://www.baidu.com/")
        let task = URLSession.shared.dataTask(with: url!) { (data, res, error) in
            
        }
        task.resume()
    }
    
    @IBOutlet weak var textfield: UITextField!
    
    @IBAction func connect(_ sender: Any) {
        session.connect(10)
    }
    
    @IBAction func send(_ sender: Any) {
        
        if let t = textfield.text {
            
            if let data =  t.data(using: .utf8) {
                session.send(data)
            }
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        
        self.textfield.resignFirstResponder()
    }
}

extension ViewController: SocketDelegate {
    func stateChanged(_ state: SocketState) {
        print("-----------> socket state changed:\(state)")
    }
    
    func errorOccurred(_ error: SSError, atState: SocketState) {
        print("-----------> errorOccurred:\(error.localizedDescription)")
    }
    
    func didRecv(_ data: Data) {
        if let str = String(data: data, encoding: .utf8) {
            print("-----------> didRecv:\(str)")
        }
    }
    
    func didSend(_ count: Int) {
        print("-----------> did send bytes count:\(count)")
    }
}

