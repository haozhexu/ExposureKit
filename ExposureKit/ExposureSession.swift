//
//  ExposureKit.swift
//  ExposureKit
//
//  Created by Haozhe XU on 18/8/20.
//  Copyright © 2020 Haozhe XU. All rights reserved.
//

import AVFoundation
import MetalKit
import Photos

public enum Camera {
    case wideAngle
    case telephoto
    case ultraWideAngle
    case front
}

public struct PhotoFormatOptions: OptionSet {

    public let rawValue: UInt
    
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let raw = PhotoFormatOptions(rawValue: 1 << 0)   // raw format if supported
    public static let ooc = PhotoFormatOptions(rawValue: 1 << 1)   // out of camera non-raw image
    
    public static let all: PhotoFormatOptions = [.raw, .ooc]
}

public enum FocusMode {
    case tap
    case auto
    case distance
}

public enum ColorEffect {
    case none
    case chrome
    case insta
    case process
    case mono
    case monoMinus
    case monoPlus
}

public enum FlashMode {
    case auto
    case on
    case off
}

public enum ExposureSessionError: Error {
    case cannotCreateAVCaptureDeviceInput
    case cannotAddAVCaptureDeviceInput
    case cannotGetCurrentDevice
    case unsupportedFocusMode(FocusMode)
    case noDataCaptured
    case notAuthorizedForPhotoLibrary
    case focusPointOfInterestFailed
    case system(Error?)
}

public enum CaptureResult {
    case success
    case error(ExposureSessionError)
}

final public class ExposureSession: NSObject {

    public private(set) var isPrepared = false

    public var availableCameras: [Camera] {
        guard self.isPrepared else {
            return []
        }
        return Array(availableDevices.keys)
    }
    
    public var availableFocusModes: [FocusMode] {
        guard self.isPrepared, let device = self.currentDevice else {
            preconditionFailure("Not prepared or no current device!")
        }
        var availableModes = [FocusMode]()
        if device.isFocusModeSupported(.locked) {
            availableModes.append(.tap)
        }
        if device.isFocusModeSupported(.autoFocus) {
            availableModes.append(.auto)
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            availableModes.append(.distance)
        }
        return availableModes
    }
    
    public var isRawSupported: Bool {
        photoOutput.__availableRawPhotoPixelFormatTypes.isEmpty == false
    }
    
    public let liveView = MTKView()
    
    public private(set) var camera: Camera = .wideAngle {
        didSet {
            if let device = availableDevices[camera] {
                updateObserverForDevice(device, previous: availableDevices[oldValue])
            }
        }
    }
    
    public var photoFormats: PhotoFormatOptions = .ooc
    
    public private(set) var focusMode: FocusMode = .auto
    
    public var focusDistance: Float? {
        assertIsPrepared()
        guard let device = currentDevice else {
            preconditionFailure("Cannot get current device!")
        }
        return device.lensPosition
    }
    
    public var flashMode: FlashMode = .off
    
    public var colorEffect: ColorEffect = .none {
        didSet {
            switch self.colorEffect {
            case .none:
                self.colorFilter = nil
            case .chrome:
                self.colorFilter = CIFilter(name: "CIPhotoEffectChrome")
            case .insta:
                self.colorFilter = CIFilter(name: "CIPhotoEffectInstant")
            case .process:
                self.colorFilter = CIFilter(name: "CIPhotoEffectProcess")
            case .mono:
                self.colorFilter = CIFilter(name: "CIPhotoEffectMono")
            case .monoMinus:
                self.colorFilter = CIFilter(name: "CIPhotoEffectTonal")
            case .monoPlus:
                self.colorFilter = CIFilter(name: "CIPhotoEffectNoir")
            }
        }
    }
    public var photoQuality: Float = 1.0
    public var exposureBiasRange: (min: Float, max: Float) {
        guard let device = self.currentDevice else {
            return (0, 0)
        }
        return (device.minExposureTargetBias, device.maxExposureTargetBias)
    }
    
    public var exposureBias: Float? {
        guard let device = self.currentDevice else {
            return 0
        }
        return device.exposureTargetBias
    }
    
    public var liveViewStabilization: Bool = false {
        didSet {
            if let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = liveViewStabilization ? .auto : .off
            }
        }
    }

    public var photoAlbumName: String?
    
    public var isStorageWorking: Bool {
        storageQueue.operationCount > 0
    }
    
    public var inputDimension: CGSize {
        guard let input = currentInput else {
            return .zero
        }
        let dimension = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        return CGSize(width: CGFloat(dimension.width), height: CGFloat(dimension.height))
    }

    public var deviceBasedOrientation = true

    public func capture(focusAt point: CGPoint? = nil, shutterEffect: (() -> Void)? = nil, completion: ((CaptureResult) -> Void)? = nil) {
        let takeRAW = photoFormats.contains(.raw)
        let takeOOC = photoFormats.contains(.ooc)
        if takeOOC || takeRAW {
            capturePhoto(focusAt: point, shutterEffect: shutterEffect, completion: completion)
        }
    }
    
    public func prepare() {
        guard self.isPrepared == false else {
            return
        }
        self.metalDevice = MTLCreateSystemDefaultDevice()
        
        self.liveView.device = metalDevice
        self.liveView.isPaused = true
        self.liveView.enableSetNeedsDisplay = false

        self.metalCommandQueue = metalDevice.makeCommandQueue()

        self.liveView.delegate = self
        self.liveView.framebufferOnly = false
        
        self.ciContext = CIContext(mtlDevice: metalDevice)
        
        self.isPrepared = true
    }
    
    public func start() {
        self.captureSession = AVCaptureSession()
        self.captureSession.beginConfiguration()
        
        //session specific configuration
        if self.captureSession.canSetSessionPreset(.photo) {
            self.captureSession.sessionPreset = .photo
        }
        self.captureSession.automaticallyConfiguresCaptureDeviceForWideColor = true
        
        //setup inputs
        self.setupInput()
        
        //setup output
        self.setupOutput()
        
        self.captureSession.commitConfiguration()
        self.captureSession.startRunning()
    }

    public func switchCamera(_ camera: Camera, completion: (() -> Void)? = nil, failure: ((ExposureSessionError?) -> Void)? = nil) {
        guard self.camera != camera else {
            return
        }
        
        guard let device = self.availableDevices[camera],
            let input = try? AVCaptureDeviceInput(device: device) else {
            failure?(.cannotCreateAVCaptureDeviceInput)
            return
        }
        
        self.captureSession.beginConfiguration()
        
        if let currentInput = self.currentInput {
            self.captureSession.removeInput(currentInput)
        }
        
        guard self.captureSession.canAddInput(input) else {
            failure?(.cannotAddAVCaptureDeviceInput)
            return
        }
        
        self.captureSession.addInput(input)
        self.currentInput = input

        if let connection = videoOutput.connections.first {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = camera.isFront
            if liveViewStabilization && connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        self.captureSession.commitConfiguration()
        
        self.camera = camera
        
        completion?()
    }
    
    public func setFocusMode(_ focusMode: FocusMode, focusDistance: Float? = nil, completion: (() -> Void)? = nil, failure: ((ExposureSessionError?) -> Void)? = nil) {
        self.assertIsPrepared()
        self.sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            guard let device = self.currentDevice else {
                failure?(.cannotGetCurrentDevice)
                return
            }
            do {
                try device.lockForConfiguration()
                let avFocusMode = focusMode.toAVFocusMode()
                if device.isExposureModeSupported(.continuousAutoExposure){
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isFocusModeSupported(avFocusMode) {
                    self.focusMode = focusMode
                    device.focusMode = avFocusMode
                    if focusMode == .distance && device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: focusDistance ?? AVCaptureDevice.currentLensPosition) { _ in
                            completion?()
                        }
                    } else {
                        completion?()
                    }
                } else {
                    failure?(.unsupportedFocusMode(focusMode))
                }
                device.unlockForConfiguration()
            } catch let e {
                failure?(.system(e))
            }
        }
    }
    
    public func setExposureBias(_ bias: Float?, completion: (() -> Void)? = nil, failure: ((Error?) -> Void)? = nil) {
        guard let device = self.currentDevice else {
            failure?(nil)
            return
        }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let targetValue = bias ?? 0
                device.setExposureTargetBias(targetValue, completionHandler: nil)
                device.unlockForConfiguration()
                completion?()
            } catch let e {
                failure?(e)
            }
        }
    }
    
    public func exposeAtPoint(_ point: CGPoint) {
        
        guard let device = self.currentDevice else {
            preconditionFailure("Current device not available!")
        }
        guard device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) else {
            return
        }
        let devicePoint = devicePointFrom(point)
        self.sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}
        }
    }
    
    // MARK: Private
    
    struct PendingTapCapture {
        let shutterEffect: (() -> Void)?
        let completion: ((CaptureResult) -> Void)?
    }
    
    private var captureSession : AVCaptureSession!
    private let sessionQueue = DispatchQueue(label: "SessionQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    private let storageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .background
        return queue
    }()
    
    private var currentInput: AVCaptureDeviceInput?
    private var availableDevices = [Camera: AVCaptureDevice]()
    private var currentDevice: AVCaptureDevice? {
        return self.availableDevices[camera]
    }
    
    private var backInput : AVCaptureInput!
    private var frontInput : AVCaptureInput!
    
    private var videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    private var handlerInProgress: [Int64: ExposureHandler] = [:]
    
    private let inflightSemaphore = DispatchSemaphore(value: 1)
    
    // MARK: - Tap Focus
    
    private var focusObserverToken: NSKeyValueObservation?
    private var pendingTapCapture: PendingTapCapture?
    
    // MARK: - Metal

    private var metalDevice : MTLDevice!
    private var metalCommandQueue : MTLCommandQueue!
    
    // MARK: - Core Image
    
    private var ciContext : CIContext!
    private var currentCIImage : CIImage?
    
    private var colorFilter: CIFilter?

    //MARK: Filters
    
    private func applyFilters(inputImage image: CIImage) -> CIImage? {
        guard let filter = self.colorFilter else {
            return image
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }
    
    private func setupInput() {
        self.availableDevices = Camera.availableCaptureDevices()
        guard let device = self.availableDevices[camera],
            let input = try? AVCaptureDeviceInput(device: device),
            self.captureSession.canAddInput(input) else {
            preconditionFailure("Does not support camera \(camera)!")
        }
        self.captureSession.addInput(input)
        self.currentInput = input
        updateObserverForDevice(device)
    }
    
    private func setupOutput() {
        let videoQueue = DispatchQueue(label: "videoQueue", qos: .userInteractive)
        self.videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        } else {
            fatalError("could not add video output")
        }
        
        self.videoOutput.connections.first?.videoOrientation = .portrait
        self.videoOutput.connections.first?.isVideoMirrored = camera.isFront
        
        if captureSession.canAddOutput(self.photoOutput) {
            captureSession.addOutput(self.photoOutput)
        }
        
        self.photoOutput.isHighResolutionCaptureEnabled = true
    }

    private func capturePhoto(focusAt point: CGPoint? = nil, shutterEffect: (() -> Void)? = nil, completion: ((CaptureResult) -> Void)? = nil) {
        if let point = point {
            let devicePoint = devicePointFrom(point)
            focusAndCapture(at: devicePoint, monitorSubjectAreaChange: true, shutterEffect: shutterEffect, completion: completion)
        } else {
            self.sessionQueue.async {
                let device = UIDevice.current
                if self.deviceBasedOrientation && device.isGeneratingDeviceOrientationNotifications, let photoOutputConnection = self.photoOutput.connection(with: .video) {
                    photoOutputConnection.videoOrientation = device.orientation.videoOrientation
                }
                let photoSettings = self.makePhotoSettings()
                if let previewFormat = photoSettings.__availablePreviewPhotoPixelFormatTypes.first {
                    photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewFormat]
                }
                let handler = ExposureHandler(requestedPhotoSettings: photoSettings, storageQueue: self.storageQueue, albumName: self.photoAlbumName, willCapturePhoto: shutterEffect) { [weak self] handler, result in
                    self?.handlerInProgress[handler.requestedPhotoSettings.uniqueID] = nil
                    completion?(result)
                }
                handler.photoFilter = { [weak self] data in
                    guard let self = self, let ciImage = CIImage(data: data), let filter = self.colorFilter else {
                        return data
                    }
                    filter.setValue(ciImage, forKey: kCIInputImageKey)
                    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)! // or .sRGB, but you camera can most likely shoot P3
                    if self.photoOutput.availablePhotoFileTypes.contains(.heif) {
                        return self.ciContext.heifRepresentation(of: filter.outputImage!, format: .RGBA8, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: self.photoQuality]) ?? data
                    } else if self.photoOutput.availablePhotoFileTypes.contains(.jpg) {
                        return self.ciContext.jpegRepresentation(of: filter.outputImage!, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: self.photoQuality]) ?? data
                    }
                    return data
                }
                self.handlerInProgress[handler.requestedPhotoSettings.uniqueID] = handler
                self.photoOutput.capturePhoto(with: photoSettings, delegate: handler)
            }
        }
    }
    
    private func makePhotoSettings() -> AVCapturePhotoSettings {

        let rawEnabled = photoFormats.contains(.raw)
        var photoSettings: AVCapturePhotoSettings

        if rawEnabled, let rawFormat = photoOutput.__availableRawPhotoPixelFormatTypes.first {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: OSType(exactly: rawFormat)!, processedFormat: [AVVideoCodecKey : AVVideoCodecType.jpeg])
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: OSType(exactly: rawFormat)!, processedFormat: [AVVideoCodecKey : AVVideoCodecType.hevc])
            } else {
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: OSType(exactly: rawFormat)!, processedFormat: [AVVideoCodecKey : AVVideoCodecType.jpeg])
            }
        } else {
            photoSettings = AVCapturePhotoSettings()
        }
        
        if photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty == false {
            photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes[0]]
        }
        
        if currentInput?.device.isFlashAvailable ?? false {
            photoSettings.flashMode = flashMode.toCaptureDeviceFlashMode()
        }
        
        photoSettings.isHighResolutionPhotoEnabled = true
        
        return photoSettings
    }
    
    private func assertIsPrepared() {
        precondition(self.isPrepared, "ExposureSession hasn't been prepared!")
    }
    
    private func focusAndCapture(at devicePoint: CGPoint, monitorSubjectAreaChange: Bool, shutterEffect: (() -> Void)? = nil, completion: ((CaptureResult) -> Void)? = nil) {
        guard let device = self.currentDevice else {
            preconditionFailure("Current device not available!")
        }
        pendingTapCapture = PendingTapCapture(shutterEffect: shutterEffect, completion: completion)
        self.sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                completion?(.error(.focusPointOfInterestFailed))
            }
        }
    }
    
    private func updateObserverForDevice(_ device: AVCaptureDevice, previous: AVCaptureDevice? = nil) {
        focusObserverToken?.invalidate()
        focusObserverToken = device.observe(\.isAdjustingFocus, options: [.new, .old, .initial], changeHandler: { [weak self] (device, change) in
            guard let self = self, let pendingCapture = self.pendingTapCapture else {
                return
            }
            if change.oldValue == true && change.newValue == false {
                self.pendingTapCapture = nil
                self.capturePhoto(shutterEffect: pendingCapture.shutterEffect, completion: pendingCapture.completion)
            }
        })
        
        if let previous = previous {
            NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: previous)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange(_:)), name: .AVCaptureDeviceSubjectAreaDidChange, object: device)
    }
    
    private func focusWithMode(_ focusMode: AVCaptureDevice.FocusMode, exposeWithMode exposureMode: AVCaptureDevice.ExposureMode, atDevicePoint point: CGPoint, monitorSubjectAreaChange: Bool) {
        guard let device = self.currentDevice else {
            return
        }
        self.sessionQueue.async {
            do {
                try device.lockForConfiguration()
                // Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                // Call -set(Focus/Exposure)Mode: to apply the new point of interest.
                if focusMode != .locked && device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = point
                    device.focusMode = focusMode
                }
                
                if exposureMode != .custom && device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = exposureMode
                }
                
                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch let error {
                NSLog("Could not lock device for configuration: \(error)")
            }
        }
    }
    
    private func devicePointFrom(_ liveViewPoint: CGPoint) -> CGPoint {
        return CGPoint(x: liveViewPoint.y / liveView.bounds.height, y: (liveView.bounds.width - liveViewPoint.x) / liveView.bounds.width)
    }
    
    @objc func subjectAreaDidChange(_ notificaiton: Notification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        self.focusWithMode(.continuousAutoFocus, exposeWithMode: .continuousAutoExposure, atDevicePoint: devicePoint, monitorSubjectAreaChange: false)
    }
}

extension ExposureSession: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        //get a CIImage out of the CVImageBuffer
        let ciImage = CIImage(cvImageBuffer: buffer)
        
        //filter it
        guard let filteredCIImage = self.applyFilters(inputImage: ciImage) else {
            return
        }
        
        self.currentCIImage = filteredCIImage
        self.liveView.draw()
    }
}

extension ExposureSession : MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    public func draw(in view: MTKView) {
        guard let ciImage = self.currentCIImage else {
            return
        }
        
        guard let commandBuffer = self.metalCommandQueue.makeCommandBuffer() else {
            return
        }
        
        guard let currentDrawable = view.currentDrawable else {
            return
        }

        let drawableOffset = CGSize(width: view.drawableSize.width - ciImage.extent.width,
                                    height: view.drawableSize.height - ciImage.extent.height)

        autoreleasepool {
            //render into the metal texture
            self.ciContext.render(ciImage,
                                  to: currentDrawable.texture,
                                  commandBuffer: commandBuffer,
                                  bounds: CGRect(origin: CGPoint(x: -drawableOffset.width / 2, y: -drawableOffset.height / 2), size: view.drawableSize),
                                  colorSpace: CGColorSpaceCreateDeviceRGB())

            //register where to draw the instructions in the command buffer once it executes
            commandBuffer.present(currentDrawable)
            //commit the command to the queue so it executes
            commandBuffer.commit()
        }
        
    }
}

extension Camera {

    var isFront: Bool {
        return self == .front
    }

    func toAVDeviceType() -> AVCaptureDevice.DeviceType {
        switch self {
        case .front, .wideAngle:
            return AVCaptureDevice.DeviceType.builtInWideAngleCamera
        case .telephoto:
            return AVCaptureDevice.DeviceType.builtInTelephotoCamera
        case .ultraWideAngle:
            return AVCaptureDevice.DeviceType.builtInWideAngleCamera
        }
    }

    func defaultCaptureDevice() -> AVCaptureDevice? {
        let deviceType = self.toAVDeviceType()
        return AVCaptureDevice.default(deviceType, for: .video, position: self.isFront ? .front : .back)
    }

    static func availableCaptureDevices() -> [Camera: AVCaptureDevice] {
        let discoverySession: AVCaptureDevice.DiscoverySession
        if #available(iOS 13.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTelephotoCamera, .builtInUltraWideCamera, .builtInWideAngleCamera],
                                                                    mediaType: .video, position: .unspecified)
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTelephotoCamera, .builtInWideAngleCamera],
                                                                    mediaType: .video, position: .unspecified)
        }
        return discoverySession.devices.reduce(into: [Camera: AVCaptureDevice]()) { (result, device) in
            result[device.toCamera()] = device
        }
    }
}

extension FocusMode {
    func toAVFocusMode() -> AVCaptureDevice.FocusMode {
        switch self {
        case .distance:
            return .locked
        case .tap:
            return .autoFocus
        case .auto:
            return .continuousAutoFocus
        }
    }
}

extension AVCaptureDevice {
    func toCamera() -> Camera {
        if self.position == .front {
            return .front
        }
        if #available(iOS 13.0, *) {
            switch self.deviceType {
            case .builtInTelephotoCamera:
                return .telephoto
            case .builtInUltraWideCamera:
                return .ultraWideAngle
            default:
                return .wideAngle
            }
        } else {
            switch self.deviceType {
            case .builtInTelephotoCamera:
                return .telephoto
            default:
                return .wideAngle
            }
        }
    }
}

extension FlashMode {
    func toCaptureDeviceFlashMode() -> AVCaptureDevice.FlashMode {
        switch self {
        case .auto:
            return .auto
        case .on:
            return .on
        case .off:
            return .off
        }
    }
}

public final class ExposureHandler: NSObject, AVCapturePhotoCaptureDelegate {
    
    let requestedPhotoSettings: AVCapturePhotoSettings
    let storageQueue: OperationQueue
    let albumName: String?
    
    var willCapturePhoto: (() -> Void)?
    var photoFilter: ((Data) -> Data)?
    var completed: ((ExposureHandler, CaptureResult) -> Void)?
    
    private var processedPhotoData: Data?
    private var rawPhotoData: Data?
    
    init(requestedPhotoSettings: AVCapturePhotoSettings, storageQueue: OperationQueue, albumName: String?, willCapturePhoto: (() -> Void)?, completed: ((ExposureHandler, CaptureResult) -> Void)?) {
        self.requestedPhotoSettings = requestedPhotoSettings
        self.storageQueue = storageQueue
        self.albumName = albumName
        self.willCapturePhoto = willCapturePhoto
        self.completed = completed
    }
    
    public func photoOutput(_ captureOutput: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        self.willCapturePhoto?()
    }
    
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
            return
        }
        let dataRepresentation = photo.fileDataRepresentation()
        if photo.isRawPhoto {
            self.rawPhotoData = dataRepresentation
        } else if let photoData = dataRepresentation {
            self.processedPhotoData = photoFilter?(photoData) ?? photoData
        }
    }
    
    public func photoOutput(_ captureOutput: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        
        guard error == nil else {
            print("Error capturing photo: \(String(describing: error))")
            self.completed?(self, .error(.system(error)))
            return
        }
        
        guard self.processedPhotoData != nil || self.rawPhotoData != nil else {
            self.completed?(self, .error(.noDataCaptured))
            return
        }
        
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard let self = self else {
                return
            }
            if status == .authorized {
                self.storageQueue.addOperation { [weak self] in
                    self?.savePhoto(settings: resolvedSettings)
                }
            } else {
                self.completed?(self, .error(.notAuthorizedForPhotoLibrary))
            }
        }
    }
    
    private func savePhoto(settings: AVCaptureResolvedPhotoSettings) {
        var temporaryDNGFileURL: URL?
        if let dngPhotoData = self.rawPhotoData {
            let rawFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(settings.uniqueID).dng")
            _ = try? dngPhotoData.write(to: rawFileURL, options: .atomic)
            temporaryDNGFileURL = rawFileURL
        }
        
        PHPhotoLibrary.savePhoto(processedData: self.processedPhotoData, rawFileURL: temporaryDNGFileURL, albumName: albumName) { [weak self] success in
            guard let self = self else {
                return
            }
            if let temporaryDNGFileURL = temporaryDNGFileURL, FileManager.default.fileExists(atPath: temporaryDNGFileURL.path)
            {
                _ = try? FileManager.default.removeItem(at: temporaryDNGFileURL)
            }
            self.completed?(self, .success)
        }
    }
}

extension PHPhotoLibrary {
    
    static func savePhoto(processedData: Data?, rawFileURL: URL?, albumName: String?, completion: ((Bool) -> Void)?) {
        if let albumName = albumName {
            if let album = albumExists(with: albumName) {
                savePhoto(processedData: processedData, rawFileURL: rawFileURL, album: album, completion: completion)
            } else {
                createAlbum(with: albumName) { album in
                    savePhoto(processedData: processedData, rawFileURL: rawFileURL, album: album, completion: completion)
                }
            }
        } else {
            savePhoto(processedData: processedData, rawFileURL: rawFileURL, album: nil, completion: completion)
        }
    }
    
    static func savePhoto(processedData: Data?, rawFileURL: URL?, album: PHAssetCollection?, completion: ((Bool) -> Void)?) {
        PHPhotoLibrary.shared().performChanges({
            let creationRequest = PHAssetCreationRequest.forAsset()
            
            if let processedData = processedData {
                creationRequest.addResource(with: .photo, data: processedData, options: nil)
                if let rawFileURL = rawFileURL {
                    let companionDNGResourceOptions = PHAssetResourceCreationOptions()
                    companionDNGResourceOptions.shouldMoveFile = true
                    creationRequest.addResource(with: .alternatePhoto, fileURL: rawFileURL, options: companionDNGResourceOptions)
                }
            } else if let rawFileURL = rawFileURL {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.shouldMoveFile = true
                creationRequest.addResource(with: .photo, fileURL: rawFileURL, options: rawOptions)
            }
            
            if let album = album, let albumRequest = PHAssetCollectionChangeRequest(for: album), let placeholder = creationRequest.placeholderForCreatedAsset {
                albumRequest.addAssets([placeholder] as NSFastEnumeration)
            }
        }) { success, _ in
            completion?(success)
        }
    }
    
    static func albumExists(with title: String) -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", title)
        guard let photoAlbum = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions).firstObject else {
            return nil
        }
        return photoAlbum
    }
    
    static func createAlbum(with title: String, completion: @escaping (PHAssetCollection?) -> Void) {
        var albumPlaceholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges {
            let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            albumPlaceholder = createAlbumRequest.placeholderForCreatedAssetCollection
        } completionHandler: { (success, error) in
            guard let albumPlaceholder = albumPlaceholder else {
                completion(nil)
                return
            }
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumPlaceholder.localIdentifier], options: nil).firstObject else {
                completion(nil)
                return
            }
            guard success else {
                completion(nil)
                return
            }
            completion(album)
        }
    }
}

private extension UIDeviceOrientation {

    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
}
