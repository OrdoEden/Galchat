//
//  UIFont+.swift
//  CleanUpAce
//
//  Created by gidon on 2026/7/22.
//

import UIKit

public enum CustomFontName: String {
    case custom = "custom"
}

extension UIFont.Weight {
    var name: String {
        switch self {
            case .black:
                return "black"
            case .bold:
                return "bold"
            case .heavy:
                return "heavy"
            case .regular:
                return "regular"
            case .light:
                return "light"
            case .medium:
                return "medium"
            case .semibold:
                return "semibold"
            case .thin:
                return "thin"
            case .ultraLight:
                return "ultraLight"
            default:
                return "regular"
        }
    }

    static func customFontWeightRegx(fontName: String) -> UIFont.Weight {
        if fontName.lowercased().contains(UIFont.Weight.black.name) {
            return .black
        }
        if fontName.lowercased().contains(UIFont.Weight.bold.name) {
            return .bold
        }
        if fontName.lowercased().contains(UIFont.Weight.heavy.name) {
            return .heavy
        }
        if fontName.lowercased().contains(UIFont.Weight.regular.name) {
            return .regular
        }
        if fontName.lowercased().contains(UIFont.Weight.light.name) {
            return .light
        }
        if fontName.lowercased().contains(UIFont.Weight.medium.name) {
            return .medium
        }
        if fontName.lowercased().contains(UIFont.Weight.semibold.name) {
            return .semibold
        }
        if fontName.lowercased().contains(UIFont.Weight.thin.name) {
            return .thin
        }
        if fontName.lowercased().contains(UIFont.Weight.ultraLight.name) {
            return .ultraLight
        }
        return .regular
    }
}

public protocol FontAdaptiveProtocol {
    var normalFont: UIFont { get } // 400
    
    var mediumFont: UIFont { get } // 500
    
    var semiboldFont: UIFont { get } // 600
        
    var boldFont: UIFont { get } // 700
    
    var heavyFont: UIFont { get } // 800
    
    var blackFont: UIFont { get } // 900
    
    func customFont(name: CustomFontName) -> UIFont
}

public extension FontAdaptiveProtocol where Self: BinaryInteger {
    var normalFont: UIFont {
        return UIFont.fontRegular(size: CGFloat(self))
    }
    
    var mediumFont: UIFont {
        return UIFont.fontMedium(size: CGFloat(self))
    }
    
    var semiboldFont: UIFont {
        return UIFont.fontSemibold(size: CGFloat(self))
    }
    
    var boldFont: UIFont {
        return UIFont.fontBold(size: CGFloat(self))
    }
    
    var heavyFont: UIFont {
        return UIFont.fontHeavy(size: CGFloat(self))
    }
    
    var blackFont: UIFont {
        return UIFont.fontBlack(size: CGFloat(self))
    }
    
    func customFont(name: CustomFontName) -> UIFont {
        return UIFont.font(customName: name, size: CGFloat(self))
    }
}

extension UIFont {
    /// 将当前字体转换为圆体 (SF Pro Rounded)
    var rounded: UIFont {
        // 尝试获取圆体设计的描述符
        guard let descriptor = fontDescriptor.withDesign(.rounded) else {
            // 如果不支持圆体（比如自定义字体），就返回原字体，防止崩溃
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// 为符合 `BinaryInteger` 协议的类型提供默认实现
public extension FontAdaptiveProtocol where Self: BinaryFloatingPoint {
    var mediumFont: UIFont {
        return UIFont.fontMedium(size: CGFloat(self))
    }
    
    var semiboldFont: UIFont {
        return UIFont.fontSemibold(size: CGFloat(self))
    }
    
    var normalFont: UIFont {
        return UIFont.fontRegular(size: CGFloat(self))
    }
    
    var boldFont: UIFont {
        return UIFont.fontBold(size: CGFloat(self))
    }
    
    var heavyFont: UIFont {
        return UIFont.fontHeavy(size: CGFloat(self))
    }
    
    var blackFont: UIFont {
        return UIFont.fontBlack(size: CGFloat(self))
    }
    
    func customFont(name: CustomFontName) -> UIFont {
        return UIFont.font(customName: name, size: CGFloat(self))
    }
}

extension Int: FontAdaptiveProtocol {}
extension Double: FontAdaptiveProtocol {}
extension Float: FontAdaptiveProtocol {}
extension CGFloat: FontAdaptiveProtocol {}

import Foundation
import UIKit

public extension UIFont {
    /// 500
    @objc static func fontMedium(size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: .medium)
    }
    
    /// 600
    @objc static func fontSemibold(size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }
    
    /// 400
    @objc static func fontRegular(size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: .regular)
    }
    
    /// 700
    @objc static func fontBold(size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: .bold)
    }
    
    /// 800
    @objc static func fontHeavy(size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: .heavy)
    }
    
    /// 900
    @objc static func fontBlack(size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: .black)
    }
    
    static func font(customName: CustomFontName, size: CGFloat) -> UIFont {
        guard let font = UIFont(name: customName.rawValue, size: size) else {
            let weight = UIFont.Weight.customFontWeightRegx(fontName: customName.rawValue)
            return UIFont.systemFont(ofSize: size, weight: weight)
        }
        return font
    }
 

    @objc static func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: weight)
    }
    
    @objc static func font(name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold {
            traits.insert(.traitBold)
        }
        traits.insert(.traitItalic)

        var descriptor = UIFontDescriptor(name: name, size: size)
        if !traits.isEmpty {
            descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}
