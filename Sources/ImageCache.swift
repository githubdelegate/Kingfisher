//
//  ImageCache.swift
//  Kingfisher
//
//  Created by Wei Wang on 15/4/6.
//
//  Copyright (c) 2017 Wei Wang <onevcat@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public extension Notification.Name {
    /**
     This notification will be sent when the disk cache got cleaned either there are cached files expired or the total size exceeding the max allowed size. The manually invoking of `clearDiskCache` method will not trigger this notification.
     
     The `object` of this notification is the `ImageCache` object which sends the notification.
     
     A list of removed hashes (files) could be retrieved by accessing the array under `KingfisherDiskCacheCleanedHashKey` key in `userInfo` of the notification object you received. By checking the array, you could know the hash codes of files are removed.
     
     The main purpose of this notification is supplying a chance to maintain some necessary information on the cached files. See [this wiki](https://github.com/onevcat/Kingfisher/wiki/How-to-implement-ETag-based-304-(Not-Modified)-handling-in-Kingfisher) for a use case on it.
     */
    
    // 扩展 添加一个静态的kf清理缓存的通知名
    public static var KingfisherDidCleanDiskCache =  Notification.Name.init("com.onevcat.Kingfisher.KingfisherDidCleanDiskCache")
    
}

/**
Key for array of cleaned hashes in `userInfo` of `KingfisherDidCleanDiskCacheNotification`.
*/
public let KingfisherDiskCacheCleanedHashKey = "com.onevcat.Kingfisher.cleanedHash"

/// It represents a task of retrieving image. You can call `cancel` on it to stop the process.
public typealias RetrieveImageDiskTask = DispatchWorkItem

/**
Cache type of a cached image.

- None:   The image is not cached yet when retrieving it.
- Memory: The image is cached in memory.
- Disk:   The image is cached in disk.
*/
public enum CacheType {
    case none, memory, disk
}

/// `ImageCache` represents both the memory and disk cache system of Kingfisher. 
/// While a default image cache object will be used if you prefer the extension methods of Kingfisher, 
/// you can create your own cache object and configure it as your need. You could use an `ImageCache`
/// object to manipulate memory and disk cache for Kingfisher.
open class ImageCache {

    //Memory
    
    /*
     设置缓存中指定键的值，并将键值对与指定成本关联。
     成本值用于计算包含在缓存中的所有对象的成本的总和。当内存是有限的，或当缓存的总成本的最大允许的总成本，缓存可以开始驱逐进程，以消除其一些元素。然而，这个驱逐过程不是在保证秩序。因此，如果你试图操纵成本值来实现某些特定的行为，后果可能会对你的程序有害。通常，明显的成本是字节值的大小。如果这些信息不是现成的，你不应该经历计算它的麻烦，因为这样做会提高使用缓存的成本。通过0成本价值如果你没有使用过，或简单地使用setobject：重点：方法，不需要成本的价值将通过。
     
     
     缓存是否会自动将丢弃的内容对象的内容已被丢弃。
     如果是真的，缓存将驱逐一个无用的内容对象的内容被丢弃后。如果虚假，它不会。默认值为真。

     */
    // 定义缓存属性
    fileprivate let memoryCache = NSCache<NSString, AnyObject>()
    
    /// The largest cache cost of memory cache. The total cost is pixel count of 
    /// all cached images in memory.
    /// Default is unlimited. Memory cache will be purged automatically when a 
    /// memory warning notification is received.
    // 缓存的最大容量，
    open var maxMemoryCost: UInt = 0 {
        didSet {// 每次设置的话都去更新缓存的属性值
            self.memoryCache.totalCostLimit = Int(maxMemoryCost)
        }
    }
    
    //Disk io任务队列，
    fileprivate let ioQueue: DispatchQueue
    fileprivate var fileManager: FileManager!
    
    ///The disk cache location.
    open let diskCachePath: String
  
    /// The default file extension appended to cached files.
    open var pathExtension: String?
    
    /// The longest time duration in second of the cache being stored in disk. 
    /// Default is 1 week (60 * 60 * 24 * 7 seconds).
    /// Setting this to a negative value will make the disk cache never expiring.
    open var maxCachePeriodInSecond: TimeInterval = 60 * 60 * 24 * 7 //Cache exists for 1 week
    
    /// The largest disk size can be taken for the cache. It is the total 
    /// allocated size of cached files in bytes.
    /// Default is no limit.
    open var maxDiskCacheSize: UInt = 0
    // 处理队列，用来对取出来的图片进行一些处理
    fileprivate let processQueue: DispatchQueue
    
    /// The default cache.
    public static let `default` = ImageCache(name: "default")
    
    /// Closure that defines the disk cache path from a given path and cacheName.
    public typealias DiskCachePathClosure = (String?, String) -> String
    
    /// The default DiskCachePathClosure 定义一个方法，这儿方法的作用是，根据路径和缓存名去拼接一个缓存路径
    public final class func defaultDiskCachePathClosure(path: String?, cacheName: String) -> String {
        let dstPath = path ?? NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
        // 如果path为空，就用默认的缓存路径
        return (dstPath as NSString).appendingPathComponent(cacheName)
    }
    
    /**
    Init method. Passing a name for the cache. It represents a cache folder in the memory and disk.
    
    - parameter name: Name of the cache. It will be used as the memory cache name and the disk cache folder name 
                      appending to the cache path. This value should not be an empty string.
    - parameter path: Optional - Location of cache path on disk. If `nil` is passed in (the default value),
                      the `.cachesDirectory` in of your app will be used.
    - parameter diskCachePathClosure: Closure that takes in an optional initial path string and generates
                      the final disk cache path. You could use it to fully customize your cache path.
    
    - returns: The cache object.
    */
    public init(name: String,
                path: String? = nil,
                diskCachePathClosure: DiskCachePathClosure = ImageCache.defaultDiskCachePathClosure)
    {
        
        if name.isEmpty {
            fatalError("[Kingfisher] You should specify a name for the cache. A cache with empty name is not permitted.")
        }
        
        // 拼接缓存名字，使用反向域名 命名 唯一
        let cacheName = "com.onevcat.Kingfisher.ImageCache.\(name)"
        memoryCache.name = cacheName
        
        // 获取缓存路径地址
        diskCachePath = diskCachePathClosure(path, cacheName)
        
        // 反向域名创建io队列
        let ioQueueName = "com.onevcat.Kingfisher.ImageCache.ioQueue.\(name)"
        ioQueue = DispatchQueue(label: ioQueueName)
        
        // 反向域名创建处理队列
        let processQueueName = "com.onevcat.Kingfisher.ImageCache.processQueue.\(name)"
        processQueue = DispatchQueue(label: processQueueName, attributes: .concurrent)
        
        // 同步的去创建文件管理器
        ioQueue.sync { fileManager = FileManager() }
        
#if !os(macOS) && !os(watchOS)
    // 接受 清理内存，将要终结，进入后台通知，去清理不同类型的缓存
        NotificationCenter.default.addObserver(
            self, selector: #selector(clearMemoryCache), name: .UIApplicationDidReceiveMemoryWarning, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(cleanExpiredDiskCache), name: .UIApplicationWillTerminate, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(backgroundCleanExpiredDiskCache), name: .UIApplicationDidEnterBackground, object: nil)
#endif
    }
    
    // 析构
    deinit {
        NotificationCenter.default.removeObserver(self)
    }


    // MARK: - Store & Remove

    /**
    Store an image to cache. It will be saved to both memory and disk. It is an async operation.
    
    - parameter image:             The image to be stored.
    - parameter original:          The original data of the image.
                                   Kingfisher will use it to check the format of the image and optimize cache size on disk.
                                   If `nil` is supplied, the image data will be saved as a normalized PNG file.
                                   It is strongly suggested to supply it whenever possible, to get a better performance and disk usage.
    - parameter key:               Key for the image.
    - parameter identifier:        The identifier of processor used. If you are using a processor for the image, pass the identifier of
                                   processor to it.
                                   This identifier will be used to generate a corresponding key for the combination of `key` and processor.
    - parameter toDisk:            Whether this image should be cached to disk or not. If false, the image will be only cached in memory.
    - parameter completionHandler: Called when store operation completes.
    */
    open func store(_ image: Image,
                      original: Data? = nil,
                      forKey key: String,
                      processorIdentifier identifier: String = "",
                      cacheSerializer serializer: CacheSerializer = DefaultCacheSerializer.default,
                      toDisk: Bool = true,
                      completionHandler: (() -> Void)? = nil)
    {
        // 添加一个图片到缓存中，图片，原始数据，key，处理标示，缓存序列化器，是否保存到磁盘，结束后的操作
        // 计算key
        let computedKey = key.computedKey(with: identifier)
        // 保持到缓存中
        memoryCache.setObject(image, forKey: computedKey as NSString, cost: image.kf.imageCost)
        // 定义函数 如果结束后有操作就在主线程中执行操作
        func callHandlerInMainQueue() {
            if let handler = completionHandler {
                DispatchQueue.main.async {
                    handler()
                }
            }
        }
        //
        if toDisk {
            ioQueue.async { // 异步的操作
                if let data = serializer.data(with: image, original: original) { // 生成图片数据
                    if !self.fileManager.fileExists(atPath: self.diskCachePath) { // 如果文件不存在
                        do {
                            try self.fileManager.createDirectory(atPath: self.diskCachePath, withIntermediateDirectories: true, attributes: nil) // 创建目录
                        } catch _ {} //
                    }
                    
                    self.fileManager.createFile(atPath: self.cachePath(forComputedKey: computedKey), contents: data, attributes: nil) // 创建文件
                }
                callHandlerInMainQueue()
            }
        } else {
            callHandlerInMainQueue()
        }
    }
    
    /**
    Remove the image for key for the cache. It will be opted out from both memory and disk. 
    It is an async operation.
    
    - parameter key:               Key for the image.
    - parameter identifier:        The identifier of processor used. If you are using a processor for the image, pass the identifier of processor to it.
                                   This identifier will be used to generate a corresponding key for the combination of `key` and processor.
    - parameter fromDisk:          Whether this image should be removed from disk or not. If false, the image will be only removed from memory.
    - parameter completionHandler: Called when removal operation completes.
    */
    // 删掉图片 key 处理标示 是否删除磁盘缓存 完成后操作
    open func removeImage(forKey key: String,
                          processorIdentifier identifier: String = "",
                          fromDisk: Bool = true,
                          completionHandler: (() -> Void)? = nil)
    {
        // 计算key
        let computedKey = key.computedKey(with: identifier)
        // 从缓存中删除
        memoryCache.removeObject(forKey: computedKey as NSString)
        // 有结束操作在主线程中执行
        func callHandlerInMainQueue() {
            if let handler = completionHandler {
                DispatchQueue.main.async {
                    handler()
                }
            }
        }
        
        if fromDisk {
            ioQueue.async{ // 异步的从文件中删掉缓存
                do {
                    try self.fileManager.removeItem(atPath: self.cachePath(forComputedKey: computedKey))
                } catch _ {}
                callHandlerInMainQueue()
            }
        } else {
            callHandlerInMainQueue()
        }
    }

    // MARK: - Get data from cache

    /**
    Get an image for a key from memory or disk.
    
    - parameter key:               Key for the image.
    - parameter options:           Options of retrieving image. If you need to retrieve an image which was 
                                   stored with a specified `ImageProcessor`, pass the processor in the option too.
    - parameter completionHandler: Called when getting operation completes with image result and cached type of 
                                   this image. If there is no such key cached, the image will be `nil`.
    
    - returns: The retrieving task.
    */
    @discardableResult
    open func retrieveImage(forKey key: String,
                               options: KingfisherOptionsInfo?,
                     completionHandler: ((Image?, CacheType) -> ())?) -> RetrieveImageDiskTask?
    {
        // No completion handler. Not start working and early return.
        guard let completionHandler = completionHandler else {
            return nil
        }
        
        var block: RetrieveImageDiskTask?
        let options = options ?? KingfisherEmptyOptionsInfo
        
        // 先从内存取图片，有直接取出执行结束
        
        // 内存中有图片
        if let image = self.retrieveImageInMemoryCache(forKey: key, options: options) {
            // 有没有回调的队列
            options.callbackDispatchQueue.safeAsync {
                completionHandler(image, .memory)
            }
        } else { // 内存没有图片
            var sSelf: ImageCache! = self
            block = DispatchWorkItem(block: {
                // Begin to load image from disk
                if let image = sSelf.retrieveImageInDiskCache(forKey: key, options: options) {
                    if options.backgroundDecode { // 需要后台处理
                        sSelf.processQueue.async {
                            let result = image.kf.decoded(scale: options.scaleFactor)
                            
                            sSelf.store(result,
                                        forKey: key,
                                        processorIdentifier: options.processor.identifier,
                                        cacheSerializer: options.cacheSerializer,
                                        toDisk: false,
                                        completionHandler: nil)
                            //
                            options.callbackDispatchQueue.safeAsync {
                                completionHandler(result, .memory)
                                sSelf = nil
                            }
                        }
                    } else { //  不需要后台处理
                        sSelf.store(image,
                                    forKey: key,
                                    processorIdentifier: options.processor.identifier,
                                    cacheSerializer: options.cacheSerializer,
                                    toDisk: false,
                                    completionHandler: nil
                        )
                        options.callbackDispatchQueue.safeAsync {
                            completionHandler(image, .disk)
                            sSelf = nil
                        }
                    }
                } else {
                    // 没有图片
                    // No image found from either memory or disk
                    options.callbackDispatchQueue.safeAsync {
                        completionHandler(nil, .none)
                        sSelf = nil
                    }
                }
            })
            
            sSelf.ioQueue.async(execute: block!)
        }
    
        return block
    }
    
    /**
    Get an image for a key from memory.
    
    - parameter key:     Key for the image.
    - parameter options: Options of retrieving image. If you need to retrieve an image which was 
                         stored with a specified `ImageProcessor`, pass the processor in the option too.
    - returns: The image object if it is cached, or `nil` if there is no such key in the cache.
    */
    open func retrieveImageInMemoryCache(forKey key: String, options: KingfisherOptionsInfo? = nil) -> Image? {
        // 从缓存中取图片
        let options = options ?? KingfisherEmptyOptionsInfo
        let computedKey = key.computedKey(with: options.processor.identifier)
        
        return memoryCache.object(forKey: computedKey as NSString) as? Image
    }
    
    /** 从磁盘上获取图片
    Get an image for a key from disk.
    
    - parameter key:     Key for the image.
    - parameter options: Options of retrieving image. If you need to retrieve an image which was
                         stored with a specified `ImageProcessor`, pass the processor in the option too.

    - returns: The image object if it is cached, or `nil` if there is no such key in the cache.
    */
    open func retrieveImageInDiskCache(forKey key: String, options: KingfisherOptionsInfo? = nil) -> Image? {
      
        // 获取属性选项，不存在就用默认的
        let options = options ?? KingfisherEmptyOptionsInfo
        // 获取计算的key
        let computedKey = key.computedKey(with: options.processor.identifier)
        //
        return diskImage(forComputedKey: computedKey, serializer: options.cacheSerializer, options: options)
    }


    // MARK: - Clear & Clean

    /**
    Clear memory cache.
    */
    @objc public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    /**
    Clear disk cache. This is an async operation.
    
    - parameter completionHander: Called after the operation completes.
    */
    open func clearDiskCache(completion handler: (()->())? = nil) {
        ioQueue.async {
            do {
                try self.fileManager.removeItem(atPath: self.diskCachePath)
                try self.fileManager.createDirectory(atPath: self.diskCachePath, withIntermediateDirectories: true, attributes: nil)
            } catch _ { }
            
            if let handler = handler {
                DispatchQueue.main.async {
                    handler()
                }
            }
        }
    }
    
    /**
    Clean expired disk cache. This is an async operation.
    */
    @objc fileprivate func cleanExpiredDiskCache() {
        cleanExpiredDiskCache(completion: nil)
    }
    
    /**
    Clean expired disk cache. This is an async operation.
    
    - parameter completionHandler: Called after the operation completes.
    */
    open func cleanExpiredDiskCache(completion handler: (()->())? = nil) {
        
        // Do things in cocurrent io queue
        ioQueue.async {
            
            var (URLsToDelete, diskCacheSize, cachedFiles) = self.travelCachedFiles(onlyForCacheSize: false)
            
            for fileURL in URLsToDelete {
                do {
                    try self.fileManager.removeItem(at: fileURL)
                } catch _ { }
            }
                
            if self.maxDiskCacheSize > 0 && diskCacheSize > self.maxDiskCacheSize {
                let targetSize = self.maxDiskCacheSize / 2
                    
                // Sort files by last modify date. We want to clean from the oldest files.
                let sortedFiles = cachedFiles.keysSortedByValue {
                    resourceValue1, resourceValue2 -> Bool in
                    
                    if let date1 = resourceValue1.contentAccessDate,
                       let date2 = resourceValue2.contentAccessDate
                    {
                        return date1.compare(date2) == .orderedAscending
                    }
                    
                    // Not valid date information. This should not happen. Just in case.
                    return true
                }
                
                for fileURL in sortedFiles {
                    
                    do {
                        try self.fileManager.removeItem(at: fileURL)
                    } catch { }
                        
                    URLsToDelete.append(fileURL)
                    
                    if let fileSize = cachedFiles[fileURL]?.totalFileAllocatedSize {
                        diskCacheSize -= UInt(fileSize)
                    }
                    
                    if diskCacheSize < targetSize {
                        break
                    }
                }
            }
                
            DispatchQueue.main.async {
                
                if URLsToDelete.count != 0 {
                    let cleanedHashes = URLsToDelete.map { $0.lastPathComponent }
                    NotificationCenter.default.post(name: .KingfisherDidCleanDiskCache, object: self, userInfo: [KingfisherDiskCacheCleanedHashKey: cleanedHashes])
                }
                
                handler?()
            }
        }
    }
    
    fileprivate func travelCachedFiles(onlyForCacheSize: Bool) -> (urlsToDelete: [URL], diskCacheSize: UInt, cachedFiles: [URL: URLResourceValues]) {
        
        let diskCacheURL = URL(fileURLWithPath: diskCachePath)
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentAccessDateKey, .totalFileAllocatedSizeKey]
        let expiredDate: Date? = (maxCachePeriodInSecond < 0) ? nil : Date(timeIntervalSinceNow: -maxCachePeriodInSecond)
        
        var cachedFiles = [URL: URLResourceValues]()
        var urlsToDelete = [URL]()
        var diskCacheSize: UInt = 0
        
        if let fileEnumerator = self.fileManager.enumerator(at: diskCacheURL, includingPropertiesForKeys: Array(resourceKeys), options: FileManager.DirectoryEnumerationOptions.skipsHiddenFiles, errorHandler: nil),
           let urls = fileEnumerator.allObjects as? [URL]
        {
            for fileUrl in urls {
                
                do {
                    let resourceValues = try fileUrl.resourceValues(forKeys: resourceKeys)
                    // If it is a Directory. Continue to next file URL.
                    if resourceValues.isDirectory == true {
                        continue
                    }
                    
                    // If this file is expired, add it to URLsToDelete
                    if !onlyForCacheSize,
                       let expiredDate = expiredDate,
                       let lastAccessData = resourceValues.contentAccessDate,
                       (lastAccessData as NSDate).laterDate(expiredDate) == expiredDate
                    {
                        urlsToDelete.append(fileUrl)
                        continue
                    }

                    if let fileSize = resourceValues.totalFileAllocatedSize {
                        diskCacheSize += UInt(fileSize)
                        if !onlyForCacheSize {
                            cachedFiles[fileUrl] = resourceValues
                        }
                    }
                } catch _ { }
            }
        }
        
        return (urlsToDelete, diskCacheSize, cachedFiles)
    }
    
#if !os(macOS) && !os(watchOS)
    /**
    Clean expired disk cache when app in background. This is an async operation.
    In most cases, you should not call this method explicitly. 
    It will be called automatically when `UIApplicationDidEnterBackgroundNotification` received.
    */
    @objc public func backgroundCleanExpiredDiskCache() {
        // if 'sharedApplication()' is unavailable, then return
        guard let sharedApplication = Kingfisher<UIApplication>.shared else { return }

        func endBackgroundTask(_ task: inout UIBackgroundTaskIdentifier) {
            sharedApplication.endBackgroundTask(task)
            task = UIBackgroundTaskInvalid
        }
        
        var backgroundTask: UIBackgroundTaskIdentifier!
        backgroundTask = sharedApplication.beginBackgroundTask {
            endBackgroundTask(&backgroundTask!)
        }
        
        cleanExpiredDiskCache {
            endBackgroundTask(&backgroundTask!)
        }
    }
#endif


    // MARK: - Check cache status
    
    /**
    *  Cache result for checking whether an image is cached for a key.
    */
    public struct CacheCheckResult {
        public let cached: Bool
        public let cacheType: CacheType?
    }
    
    /**
    Check whether an image is cached for a key.
    
    - parameter key: Key for the image.
    
    - returns: The check result.
    */
    open func isImageCached(forKey key: String, processorIdentifier identifier: String = "") -> CacheCheckResult {
        
        let computedKey = key.computedKey(with: identifier)
        
        if memoryCache.object(forKey: computedKey as NSString) != nil {
            return CacheCheckResult(cached: true, cacheType: .memory)
        }
        
        let filePath = cachePath(forComputedKey: computedKey)
        
        var diskCached = false
        ioQueue.sync {
            diskCached = fileManager.fileExists(atPath: filePath)
        }

        if diskCached {
            return CacheCheckResult(cached: true, cacheType: .disk)
        }
        
        return CacheCheckResult(cached: false, cacheType: nil)
    }
    
    /**
    Get the hash for the key. This could be used for matching files.
    
    - parameter key:        The key which is used for caching.
    - parameter identifier: The identifier of processor used. If you are using a processor for the image, pass the identifier of processor to it.
    
     - returns: Corresponding hash.
    */
    open func hash(forKey key: String, processorIdentifier identifier: String = "") -> String {
        let computedKey = key.computedKey(with: identifier)
        return cacheFileName(forComputedKey: computedKey)
    }
    
    /**
    Calculate the disk size taken by cache. 
    It is the total allocated size of the cached files in bytes.
    
    - parameter completionHandler: Called with the calculated size when finishes.
    */
    open func calculateDiskCacheSize(completion handler: @escaping ((_ size: UInt) -> ())) {
        ioQueue.async {
            let (_, diskCacheSize, _) = self.travelCachedFiles(onlyForCacheSize: true)
            DispatchQueue.main.async {
                handler(diskCacheSize)
            }
        }
    }
    
    /**
    Get the cache path for the key.
    It is useful for projects with UIWebView or anyone that needs access to the local file path.
    
    i.e. Replace the `<img src='path_for_key'>` tag in your HTML.
     
    - Note: This method does not guarantee there is an image already cached in the path. It just returns the path
      that the image should be.
      You could use `isImageCached(forKey:)` method to check whether the image is cached under that key.
    */
    open func cachePath(forKey key: String, processorIdentifier identifier: String = "") -> String {
        let computedKey = key.computedKey(with: identifier)
        return cachePath(forComputedKey: computedKey)
    }

    // 根据键key获取缓存的路径地址
    open func cachePath(forComputedKey key: String) -> String {
        // 拼接获取缓存文件的名字
        let fileName = cacheFileName(forComputedKey: key)
        // 把缓存路径拼接文件名返回
        return (diskCachePath as NSString).appendingPathComponent(fileName)
    }
}

// MARK: - Internal Helper
extension ImageCache {
  // 根据键 序列化对象 选项 去获取图片
    func diskImage(forComputedKey key: String, serializer: CacheSerializer, options: KingfisherOptionsInfo) -> Image? {
        if let data = diskImageData(forComputedKey: key) {
            return serializer.image(with: data, options: options)
        } else {
            return nil
        }
    }
    
    // 根据键去获取img的数据
    func diskImageData(forComputedKey key: String) -> Data? {
        // 获取缓存的文件路径地址
        let filePath = cachePath(forComputedKey: key)
        // 获取数据data
        return (try? Data(contentsOf: URL(fileURLWithPath: filePath)))
    }
    
    // 根据key 获取缓存的文件名字
    func cacheFileName(forComputedKey key: String) -> String {
        // 如果有扩展名 就在后面拼接扩展名
        if let ext = self.pathExtension {
          return (key.kf.md5 as NSString).appendingPathExtension(ext)!
        }
        // 返回键key的md5，md5 能保证唯一
        return key.kf.md5
    }
}


extension Kingfisher where Base: Image {
    var imageCost: Int {
        return images == nil ? // images 表示images 属性，包含多张图片
            Int(size.height * size.width * scale * scale) :
            Int(size.height * size.width * scale * scale) * images!.count
    }
}

extension Dictionary {// 扩展字典实现，key能够按照value的值进行排序，返回的是经过排序后的key的数组。
    func keysSortedByValue(_ isOrderedBefore: (Value, Value) -> Bool) -> [Key] {
        return Array(self).sorted{ isOrderedBefore($0.1, $1.1) }.map{ $0.0 }
    }
}

#if !os(macOS) && !os(watchOS)
// MARK: - For App Extensions
extension UIApplication: KingfisherCompatible { }
extension Kingfisher where Base: UIApplication {
    public static var shared: UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard Base.responds(to: selector) else { return nil }
        return Base.perform(selector).takeUnretainedValue() as? UIApplication
    }
}
#endif

extension String {
    // 扩展string 计算一个key 拼接
    func computedKey(with identifier: String) -> String {
        if identifier.isEmpty {
            return self
        } else {
            return appending("@\(identifier)")
        }
    }
}
