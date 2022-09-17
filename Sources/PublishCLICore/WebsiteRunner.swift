/**
 *  Publish
 *  Copyright (c) John Sundell 2019
 *  MIT license, see LICENSE file for details
 */

import Foundation
import Files
import ShellOut
import FileWatcher

internal struct WebsiteRunner {
    static let normalTerminationStatus = 15
    static let debounceInterval: TimeInterval = 3
    let folder: Folder
    let portNumber: Int
    let shouldWatch: Bool

    func run() throws {
        var lastModified: Date?
        var watcher: FileWatcher?
        let serverProcess: Process = try generateAndRun()

        if shouldWatch {
            watcher = try startWatcher {
                if lastModified == nil {
                    let file = try? File(path: $0)
                    print("Change detected at \(file?.name ?? "Unknown"), scheduling regeneration")
                }
                lastModified = Date()
            }
        }

        let teardown: () -> Void = {
            watcher?.stop()
            serverProcess.terminate()
        }

        let interruptHandler = registerInterruptHandler {
            teardown()
            exit(0)
        }

        interruptHandler.resume()

        defer {
            teardown()
        }

        while true {
            defer {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            }

            guard let date = lastModified, date.timeIntervalSinceNow < -Self.debounceInterval else {
                continue
            }

            lastModified = nil

            print("Regenerating...")
            let generator = WebsiteGenerator(folder: folder)
            do {
                try generator.generate()
            } catch {
                outputErrorMessage("Regeneration failed")
            }
        }
    }
}

private extension WebsiteRunner {
    var foldersToWatch: [Folder] {
        get throws {
            try ["Sources", "Resources", "Content"].map(folder.subfolder(named:))
        }
    }

    func startWatcher(_ didChange: @escaping (String) -> Void) throws -> FileWatcher {
        let filePaths = try foldersToWatch.map(\.path)
        let watcher = FileWatcher(filePaths)

        watcher.callback = { event in
            if event.isFileChanged || event.isDirectoryChanged {
                didChange(event.path)
            }
        }

        watcher.start()
        return watcher
    }

    func registerInterruptHandler(_ handler: @escaping () -> Void) -> DispatchSourceSignal {
        let interruptHandler = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

        signal(SIGINT, SIG_IGN)

        interruptHandler.setEventHandler(handler: handler)
        return interruptHandler
    }

    func generate() throws {
        let generator = WebsiteGenerator(folder: folder)
        try generator.generate()
    }

    func generateAndRun() throws -> Process {
        try generate()

        let outputFolder = try resolveOutputFolder()

        let serverQueue = DispatchQueue(label: "Publish.WebServer")
        let serverProcess = Process()

        print("""
        🌍 Starting web server at http://localhost:\(portNumber)

        Press ENTER to stop the server and exit
        """)

        serverQueue.async {
            var isNormalTermination = false

            do {
                _ = try shellOut(
                    to: "python -m \(self.resolvePythonHTTPServerCommand()) \(self.portNumber)",
                    at: outputFolder.path,
                    process: serverProcess
                )
            } catch let error as ShellOutError where error.terminationStatus == Self.normalTerminationStatus {
                isNormalTermination = true
            } catch let error as ShellOutError {
                self.outputServerErrorMessage(error.message)
            } catch {
                self.outputServerErrorMessage(error.localizedDescription)
            }

            if !isNormalTermination {
                serverProcess.terminate()
                exit(1)
            }
        }

        return serverProcess
    }

    func resolveOutputFolder() throws -> Folder {
        do { return try folder.subfolder(named: "Output") }
        catch { throw CLIError.outputFolderNotFound }
    }

    func resolvePythonHTTPServerCommand() -> String {
        if resolveSystemPythonMajorVersionNumber() >= 3 {
            return "http.server"
        } else {
            return "SimpleHTTPServer"
        }
    }

    func resolveSystemPythonMajorVersionNumber() -> Int {
        // Expected output: `Python X.X.X`
        let pythonVersionString = try? shellOut(to: "python --version")
        let fullVersionNumber = pythonVersionString?.split(separator: " ").last
        let majorVersionNumber = fullVersionNumber?.first
        return majorVersionNumber?.wholeNumberValue ?? 2
    }

    func outputServerErrorMessage(_ message: String) {
        var message = message

        if message.hasPrefix("Traceback"),
           message.contains("Address already in use") {
            message = """
            A localhost server is already running on port number \(portNumber).
            - Perhaps another 'publish run' session is running?
            - Publish uses Python's simple HTTP server, so to find any
              running processes, you can use either Activity Monitor
              or the 'ps' command and search for 'python'. You can then
              terminate any previous process in order to start a new one.
            """
        }

        outputErrorMessage("Failed to start local web server:\n\(message)")
    }

    func outputErrorMessage(_ message: String) {
        fputs("\n❌ \(message)\n", stderr)
    }
}

extension FileWatcherEvent {
    var isFileChanged: Bool {
        fileRenamed || fileRemoved || fileCreated || fileModified
    }

    var isDirectoryChanged: Bool {
        dirRenamed || dirRemoved || dirCreated || dirModified
    }
}
