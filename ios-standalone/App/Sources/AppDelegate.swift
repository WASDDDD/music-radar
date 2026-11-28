import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        do {
            let port = try Backend.shared.start()
            let vc = ViewController(port: port)
            let nav = UINavigationController(rootViewController: vc)
            nav.setNavigationBarHidden(true, animated: false)
            nav.navigationBar.prefersLargeTitles = false
            let ap = UINavigationBarAppearance()
            ap.configureWithOpaqueBackground()
            ap.backgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.07, alpha: 1)
            ap.titleTextAttributes = [.foregroundColor: UIColor.white]
            ap.buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
            nav.navigationBar.standardAppearance = ap
            nav.navigationBar.scrollEdgeAppearance = ap
            nav.navigationBar.tintColor = .white
            window?.rootViewController = nav
        } catch {
            let label = UILabel()
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .white
            label.backgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.07, alpha: 1)
            label.text = "本地服务启动失败\n\(error)"
            let vc = UIViewController()
            vc.view.backgroundColor = label.backgroundColor
            vc.view.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -24),
                label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor)
            ])
            window?.rootViewController = vc
        }
        window?.makeKeyAndVisible()
        return true
    }
}
