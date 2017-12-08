/**
 * Copyright IBM Corporation 2016, 2017
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Kitura
import KituraNet
import KituraSession
import LoggerAPI
import Foundation

// MARK Credentials

/// A pluggable framework for validating user credentials.
public class Credentials : RouterMiddleware {
    var nonRedirectingPlugins = [CredentialsPluginProtocol]()
    var redirectingPlugins = [String : CredentialsPluginProtocol]()
    
    /// The dictionary of options to pass to the plugins.
    public var options: [String:Any]
    
    /// Initialize a `Credentials` instance.
    public convenience init () {
        self.init(options: [String:Any]())
    }
    
    /// Initialize a `Credentials` instance.
    ///
    /// - Parameter options: The dictionary of options to pass to the plugins.
    public init (options: [String:Any]) {
        self.options = options
    }
    
    /// Handle an incoming request: authenticate the request using the registered plugins.
    ///
    /// - Parameter request: The `RouterRequest` object used to get information
    ///                     about the request.
    /// - Parameter response: The `RouterResponse` object used to respond to the
    ///                       request.
    /// - Parameter next: The closure to invoke to enable the Router to check for
    ///                  other handlers or middleware to work with this request.
    public func handle(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        if (nonRedirectingPlugins.count == 0 && redirectingPlugins.count == 0) {
            Log.error("No plugins registered to Kitura-Credentials")
            next()
            return
        }
        
        if let session = request.session  {
            if let _ = request.userProfile {
                next()
                return
            }
            else {
                if let userProfile = Credentials.restoreUserProfile(from: session) {
                    request.userProfile = userProfile
                    next()
                    return
                }
            }
        }
        
        var pluginIndex = -1
        var passStatus : HTTPStatusCode?
        var passHeaders : [String:String]?
        
        // Extra variable to get around use of variable in its own initializer
        var callback: (()->Void)? = nil
        
        let callbackHandler = {[unowned request, unowned response, next] () -> Void in
            pluginIndex += 1
            if pluginIndex < self.nonRedirectingPlugins.count {
                let plugin = self.nonRedirectingPlugins[pluginIndex]
                plugin.authenticate(request: request, response: response, options: self.options,
                                    onSuccess: { userProfile in
                                        request.userProfile = userProfile
                                        next()
                },
                                    onFailure: { status, headers in
                                        self.fail(response: response, status: status, headers: headers)
                },
                                    onPass: { status, headers in
                                        // First pass parameters are saved
                                        if let status = status, passStatus == nil {
                                            passStatus = status
                                            passHeaders = headers
                                        }
                                        callback!()
                },
                                    inProgress: {
                                        self.redirectUnauthorized(response: response)
                                        next()
                }
                )
            }
            else {
                // All the plugins passed
                if request.session != nil, !self.redirectingPlugins.isEmpty {
                    Credentials.setRedirectingReturnTo(request.originalURL, for: request)
                    self.redirectUnauthorized(response: response)
                }
                else {
                    if request.session == nil && !self.redirectingPlugins.isEmpty && self.nonRedirectingPlugins.isEmpty {
                        Log.error("The authentication failed because a session, required by redirecting authentication, was not configured.")
                    }
                    self.fail(response: response, status: passStatus, headers: passHeaders)
                }
            }
        }
        
        callback = callbackHandler
        callbackHandler()
    }
    
    /// Get the URL to which the flow will return to after successfully authenticating using a redirecting plugin.
    ///
    /// - Note: By default, it is set to `request.originalURL`.
    ///
    /// - Parameter for request: The `RouterRequest` to get the URL.
    /// - Returns: A String containing the URL, or nil if there is no session or the URL is not set.
    public static func getRedirectingReturnTo(for request: RouterRequest) -> String? {
        guard let session = request.session, session["returnTo"] != nil else {
            //        guard let session = request.session, session["returnTo"].type != .null else {
            return nil
        }
        return (session["returnTo"] as? String) ?? ""
    }
    
    /// Set the URL to which the flow will return to after successfully authenticating using a redirecting plugin.
    ///
    /// - Note: By default, it is set to `request.originalURL`.
    ///
    /// - Parameter for request: The `RouterRequest` to set the URL.
    public static func setRedirectingReturnTo(_ returnTo: String, for request: RouterRequest) {
        if let session = request.session {
            session["returnTo"] = returnTo
        }
    }
    
    private func fail (response: RouterResponse, status: HTTPStatusCode?, headers: [String:String]?) {
        let responseStatus = status ?? .unauthorized
        if let headers = headers {
            for (key, value) in headers {
                response.headers.append(key, value: value)
            }
        }
        do {
            try response.status(responseStatus).end()
        }
        catch {
            Log.error("Failed to send response")
        }
    }
    
    /// Register a plugin implementing `CredentialsPluginProtocol`.
    ///
    /// - Parameter plugin: An implementation of `CredentialsPluginProtocol`. The credentials
    ///                 framework invokes registered plugins to authenticate incoming requests.
    public func register (plugin: CredentialsPluginProtocol) {
        if plugin.redirecting {
            redirectingPlugins[plugin.name] = plugin
        }
        else {
            nonRedirectingPlugins.append(plugin)
            nonRedirectingPlugins[nonRedirectingPlugins.count - 1].usersCache = NSCache()
        }
    }
    
    private func redirectUnauthorized (response: RouterResponse, path: String?=nil) {
        let redirect: String?
        if let path = path {
            redirect = path
        }
        else {
            redirect = options["failureRedirect"] as? String
        }
        if let redirect = redirect {
            do {
                try response.redirect(redirect)
            }
            catch {
                response.error = NSError(domain: "Credentials", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to redirect unauthorized request"])
            }
        }
        else {
            do {
                try response.status(.unauthorized).end()
            }
            catch {
                Log.error("Failed to send response")
            }
        }
    }
    
    private func redirectAuthorized (response: RouterResponse, path: String?=nil) {
        let redirect : String?
        if let path = path {
            redirect = path
        }
        else {
            redirect = options["successRedirect"] as? String
        }
        if let redirect = redirect {
            do {
                try response.redirect(redirect)
            }
            catch {
                response.error = NSError(domain: "Credentials", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to redirect successfuly authorized request"])
            }
        }
    }
    
    /// Create a `RouterHandler` that invokes the specific redirecting plugin to authenticate incoming requests.
    ///
    /// - Parameter credentialsType: The name of a registered redirecting plugin that will be used for request authentication.
    /// - Parameter successRedirect: The path to redirect to if the authentication is successful.
    /// - Parameter failureRedirect: The path to redirect to if the authentication failed.
    /// - Returns: A `RouterHandler` for request authentication.
    public func authenticate (credentialsType: String, successRedirect: String?=nil, failureRedirect: String?=nil) -> RouterHandler {
        return { request, response, next in
            if let session = request.session {
                if let plugin = self.redirectingPlugins[credentialsType] {
                    plugin.authenticate(request: request, response: response, options: self.options,
                                        onSuccess: { userProfile in
                                            Credentials.store(userProfile: userProfile, in: session)
                                            var redirect: String?
                                            if let returnTo = Credentials.getRedirectingReturnTo(for: request) {
                                                redirect = returnTo
                                                session.remove(key: "returnTo")
                                            }
                                            else {
                                                redirect = successRedirect
                                            }
                                            self.redirectAuthorized(response: response, path: redirect)
                                            next()
                    },
                                        onFailure: { _, _ in
                                            self.redirectUnauthorized(response: response, path: failureRedirect)
                    },
                                        onPass: { _, _ in
                                            self.redirectUnauthorized(response: response, path: failureRedirect)
                    },
                                        inProgress: {
                                            next()
                    }
                    )
                }
                else {
                    do {
                        try response.status(.unauthorized).end()
                    }
                    catch {
                        Log.error("Failed to send response")
                    }
                    next()
                }
            }
            else {
                let error = "The server was not configured properly: no session found for redirecting authentication"
                Log.error(error)
                response.error = NSError(domain: "Credentials", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
        }
    }
    
    /// Delete the user profile information from the session and the request.
    ///
    /// - Parameter request: The `RouterRequest` object used to get information
    ///                     about the request.
    public func logOut (request: RouterRequest) {
        if let session = request.session  {
            request.userProfile = nil
            session.remove(key: "userProfile")
        }
    }
    
    static func restoreUserProfile(from session: SessionState) -> UserProfile? {
        let sessionUserProfile = session["userProfile"]
        if sessionUserProfile != nil  {
            if let dictionary = sessionUserProfile as? [String:Codable],
                let displayName = dictionary["displayName"] as? String,
                let provider = dictionary["provider"] as? String,
                let id = dictionary["id"] as? String {
                
                var userName: UserProfile.UserProfileName?
                if let familyName = dictionary["familyName"] as? String,
                    let givenName = dictionary["givenName"] as? String,
                    let middleName = dictionary["middleName"] as? String {
                    userName = UserProfile.UserProfileName(familyName: familyName, givenName: givenName, middleName: middleName)
                }
                
                var userEmails: [UserProfile.UserProfileEmail]?
                
                if let emails = dictionary["emails"] as? [String],
                    let types = dictionary["emailTypes"] as? [String] {
                    userEmails = []
                    
                    for (index, email) in emails.enumerated() {
                        let userEmail = UserProfile.UserProfileEmail(value: email, type: types[index])
                        userEmails?.append(userEmail)
                    }
                }
                
                var userPhotos: [UserProfile.UserProfilePhoto]?
                
                if let photos = dictionary["photos"] as? [String] {
                    userPhotos = []
                    
                    for photo in photos {
                        let userPhoto = UserProfile.UserProfilePhoto(photo)
                        userPhotos?.append(userPhoto)
                    }
                }
                
                return UserProfile(id: id, displayName: displayName, provider: provider, name: userName, emails: userEmails, photos: userPhotos, extendedProperties: dictionary["extendedProperties"] as? [String:Any])
            }
        }
        return nil
    }
    
    private static func store(userProfile: UserProfile, in session: SessionState) {
        var dictionary = [String:Codable]()
        dictionary["displayName"] = userProfile.displayName
        dictionary["provider"] = userProfile.provider
        dictionary["id"] = userProfile.id
        
        if let name = userProfile.name {
            dictionary["familyName"] = name.familyName
            dictionary["givenName"] = name.givenName
            dictionary["middleName"] = name.middleName
        }
        
        if let emails = userProfile.emails {
            var emailsArray = [String]()
            var emailTypesArray = [String]()
            for email in emails {
                emailsArray.append(email.value)
                emailTypesArray.append(email.type)
            }
            dictionary["emails"] = emailsArray
            dictionary["emailTypes"] = emailTypesArray
        }
        
        if let photos = userProfile.photos {
            var photosArray = [String]()
            for photo in photos {
                photosArray.append(photo.value)
            }
            dictionary["photos"] = photosArray
        }
        
        if !userProfile.extendedProperties.isEmpty {
            dictionary["extendedProperties"] = userProfile.extendedProperties
        }
        
        session["userProfile"] = dictionary
    }
}

