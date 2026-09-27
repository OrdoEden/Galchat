//
//  String+.swift
//  CleanUpAce
//
//  Created by gidon on 2026/7/22.
//

import Foundation
import UIKit
import SwiftUI

extension String {
    /// 十六进制颜色转换为UIColor
    public var toRGB: UIColor {
        return uicolor(alpha: 1.0, p3: false)
    }
    
    public var toP3: UIColor {
        return uicolor(alpha: 1.0, p3: true)
    }
    
    public func toUIColor(alpha: CGFloat = 1.0, isDisplayP3: Bool = false) -> UIColor {
        return uicolor(alpha: alpha, p3: isDisplayP3)
    }
    
    /// 十六进制颜色转换为UIColor
    /// - Parameter alpha: 透明度
    /// - Returns: UIColor
    public func uicolor(alpha: CGFloat? = 1.0, p3: Bool = false) -> UIColor {
        var red: UInt64 = 0, green: UInt64 = 0, blue: UInt64 = 0, _alpha: UInt64 = 0
        var hex = self
        // 去掉前缀
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex[hex.index(hex.startIndex, offsetBy: 2)...])
        } else if hex.hasPrefix("#"){
            hex = String(hex[hex.index(hex.startIndex, offsetBy: 1)...])
        }
        
        // 如果位数不足补0
        if hex.count < 6 {
            for _ in 0..<6-hex.count {
                hex += "0"
            }
        }
        
        Scanner(string: String(hex[..<hex.index(hex.startIndex, offsetBy: 2)])).scanHexInt64(&red)
        Scanner(string: String(hex[hex.index(hex.startIndex, offsetBy: 2)..<hex.index(hex.startIndex, offsetBy: 4)])).scanHexInt64(&green)
        Scanner(string: String(hex[hex.index(hex.startIndex, offsetBy: 4)..<hex.index(hex.startIndex, offsetBy: 6)])).scanHexInt64(&blue)
        if hex.count == 8 {
            Scanner(string: String(hex[hex.index(hex.startIndex, offsetBy: 6)...])).scanHexInt64(&_alpha)
            return UIColor(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: CGFloat(_alpha) / 255.0)
        }
        
        if p3 == true {
            return UIColor(displayP3Red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: alpha ?? 1.0)
        }
        return UIColor(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: alpha ?? 1.0)
    }
}

@available(iOS 13.0, *)
extension String {
    @available(iOS 13.0, *)
    public var toColor: Color {
        return Color(self.toRGB)
    }
    
    @available(iOS 13.0, *)
    public var toP3Color: Color {
        return Color(self.toRGB)
    }
    
    @available(iOS 13.0, *)
    public func toColor(alpha: CGFloat = 1.0, isDisplayP3: Bool = false) -> Color {
        return Color(self.toUIColor(alpha: alpha, isDisplayP3: isDisplayP3))
    }
    
    @available(iOS 13.0, *)
    public func color(alpha: CGFloat = 1.0, p3: Bool = true) -> Color {
        return Color(self.uicolor(alpha: alpha, p3: p3))
    }
}


extension UIDevice {
	static var appName: String {
		let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Galchat"
		return appName
	}
}

extension NSString {
    @objc var local: String {
        return self.local()
    }
    
    @objc func local(params: [NSString]) -> String {
        return String(format: (self as String).local, arguments: params)
    }
    
    @objc func local(param: NSString) -> String {
        return String(format: (self as String).local, param)
    }
    
    func local(_ tableName: String = "Localizable") -> String {
        return NSLocalizedString(self as String, tableName: tableName, comment: "")
    }
}

extension String {
    var local: String {
        return self.local()
    }
    
    func local(params: [String]) -> String {
        return String(format: self.local, arguments: params)
    }
    
    func local(param: String) -> String {
        return String(format: self.local, param)
    }
    
    func local(_ tableName: String = "Localizable") -> String {
        return NSLocalizedString(self, tableName: tableName, comment: "")
    }

    func localAppxyUniversal() -> String {
        return NSLocalizedString(self, tableName: "AppxyUniversal", comment: "")
    }
}
