//
//  UIButton+Ex.swift
//  CleanUpAce
//
//  Created by gidon on 2026/7/22.
//

import UIKit

extension UIButton {
    public static func makeBackButtonConfiguration(adaptedIos26: Bool = true) -> Configuration {
        if #available(iOS 26.0, *), adaptedIos26 {
            var config = UIButton.Configuration.glass()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
            return config
        } else {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
            return config
        }
    }

    public static func makeButtonConfiguration(adaptedIos26: Bool = true) -> Configuration {
        if #available(iOS 26.0, *), adaptedIos26 {
            var config = UIButton.Configuration.glass()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
            return config
        } else {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
            return config
        }
    }

    // Objective-C 兼容版本保持不变
    @objc public static func createAdaptedButton() -> UIButton {
        return UIButton(configuration: makeButtonConfiguration())
    }
    
    @objc public static func createAdaptedBackButton() -> UIButton {
        return UIButton(configuration: makeBackButtonConfiguration())
    }
}
