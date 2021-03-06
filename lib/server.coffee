# Dependencies
chokidar = require 'chokidar'
CSON = require 'cson'
Firebase = require 'firebase'
express = require 'express'
fs = require 'fs'
LRU = require 'lru-cache'
path = require 'path'
wrap = require 'asset-wrap'


# Exports
exports = module.exports = (cfg) ->


  # Settings
  _cache = new LRU {max: 50, maxAge: 1000*60*5}
  prod = process.env.LT3_ENV == 'prod'
  logger = if prod then 'default' else 'dev'
  useCache = prod
  useCompression = prod
  pkg_dir = cfg.pkg_dir or path.join __dirname, '..', '..', '..', 'pkg'


  # Local Deveopment Variables
  firebase = null
  user = null


  # Helpers
  package_dir = (id, version) ->
    path.join pkg_dir, id, version

  read_package = (id, version) ->
    root = package_dir id, version
    f = path.join root, 'config.cson'
    CSON.parseFileSync f if fs.existsSync f


  # Watch For File Changes
  unless prod
    watcher = chokidar.watch pkg_dir, {
      ignored: /(^\.|\.swp$|\.tmp$|~$)/
    }
    watcher.on 'change', (filepath) ->
      filepath = filepath.replace pkg_dir, ''
      re = /^[\/\\]([^\/\\]*)[\/\\]([^\/\\]*)[\/\\].*$/
      [filepath, id, version] = filepath.match(re) or []
      console.log "#{id} v#{version} updated"
      if user
        pkg = read_package id, version
        return unless pkg
        delete pkg.changelog
        ref = firebase.child "users/#{user}/developer/listener"
        pkg.modified = Date.now()
        ref.set pkg


  # Middleware
  (req, res, next) ->

    # Helpers
    cacheHeaders = (age) ->
      val = "private, max-age=0, no-cache, no-store, must-revalidate"
      if useCache
        [num, type] = [age, 'seconds']
        if typeof age == 'string'
          [num, type] = age.split ' '
          num = parseInt num, 10
        if num == 0
          val = 'private, max-age=0, no-cache, no-store, must-revalidate'
        else
          switch type
            when 'minute', 'minutes'  then num *= 60
            when 'hour', 'hours'      then num *= 3600
            when 'day', 'days'        then num *= 86400
            when 'week', 'weeks'      then num *= 604800
          val = "public, max-age=#{num}, must-revalidate"
      res.set 'Cache-Control', val

    cache = (options, fn) ->
      # options
      unless fn
        fn = options
        options = {age: '10 minutes'}

      if typeof options is 'string'
        options = {age: options}

      # headers
      cacheHeaders options.age

      # response
      url = if options.qs then req.url else req._parsedUrl.pathname
      key = "#{req.protocol}://#{req.host}#{url}"
      if prod and _cache.has key
        res.send _cache.get key
      else
        fn (data) =>
          _cache.set key, data
          res.send data

    contentType = (type) ->
      res.set 'Content-Type', type

    error = (code, msg) ->
      unless msg
        switch code
          when 400 then msg = 'Bad Request'
          when 404 then msg = 'Page Not Found'
          when 500 then msg = 'Internal Server Error'

      console.error """

      === ERROR: #{code} ===
      """
      res.send code, msg
      console.error """
      ===
      #{msg}
      === END ERROR ===

      """


    # Routes
    router = new express.Router()

    # Access Control Allow Origin
    router.route 'GET', '*', (req, res, next) ->
      res.header "Access-Control-Allow-Origin", "*"
      next()

    # Development Token
    unless prod
      router.route 'GET', '/connect', (req, res, next) ->
        token = req.query.token
        firebase = new Firebase 'https://lessthan3.firebaseio.com'
        firebase.auth token, (err, data) ->
          return error 400 if err
          user = req.query.user._id

          pkg = {}
          for i, id of fs.readdirSync pkg_dir
            pkg[id] = {}
            pkg_path = "#{pkg_dir}/#{id}"
            continue unless fs.lstatSync(pkg_path).isDirectory()
            for i, version of fs.readdirSync pkg_path
              pkg[id][version] = 1
          res.send pkg

    # Package Info
    router.route 'GET', '/pkg/:id/:version/config.json', (req, res, next) ->
      contentType 'application/json'
      cache {age: '10 minutes'}, (next) =>
        next read_package req.params.id, req.params.version

    router.route 'GET', '/pkg/:id/:version/package.json', (req, res, next) ->
      contentType 'application/json'
      cache {age: '10 minutes'}, (next) =>
        next read_package req.params.id, req.params.version


    # Package Javascript
    router.route 'GET', '/pkg/:id/:version/main.js', (req, res, next) ->
      contentType 'text/javascript'
      cache {age: '10 minutes'}, (next) =>
        build = (id, version) ->
          root = package_dir id, version
          pkg = read_package id, version
          return [] unless pkg
          js = []

          if pkg.dependencies
            js = js.concat(build(k, v)) for k, v of pkg.dependencies

          add = (src, page=null) ->
            return unless src
            return unless fs.existsSync src
            return unless fs.lstatSync(src).isFile()
            asset = new wrap.Snockets {src: src}
            asset.pkg = pkg
            asset.page = page
            js.push asset

          paths = ['main', 'header', 'footer', 'app']
          add path.join(root, "#{p}.coffee") for p in paths
          add path.join(root, pkg.main?.js or '')

          if pkg.type == 'app' and pkg.pages
            for type of pkg.pages
              add path.join(root, 'pages', "#{type}.coffee"), type
          js

        js = new wrap.Assets build(req.params.id, req.params.version), {
          compress: useCompression
        }, (err) =>
          return error 500, err.toString() if err
          try
            header = ""
            for a in js.assets
              v = "window.lt3"
              w = "lt3.pkg"
              x = "lt3.pkg['#{a.pkg.id}']"
              y = "#{x}['#{a.pkg.version}']"
              z = "#{y}.Pages"

              check = (str) -> ";if(#{str}==null){#{str}={};};"
              unless a.page
                header += check(v) + check(w) + check(x) + check(y)
                header += check(z) if a.pkg.type == 'app'
                header += "#{y}.package = #{JSON.stringify a.pkg};"
                header += "#{y}.config = #{JSON.stringify a.pkg};"
              a.data = a.data.replace 'exports.App', "#{y}.App"
              a.data = a.data.replace 'exports.Header', "#{y}.Header"
              a.data = a.data.replace 'exports.Footer', "#{y}.Footer"
              a.data = a.data.replace 'exports.Component', "#{y}.Component"
              a.data = a.data.replace 'exports.Page', "#{z}['#{a.page}']"
            asset = js.merge (err) ->
              next header + asset.data
          catch err
            error 500, err.stack

    # Package Stylesheet
    router.route 'GET', '/pkg/:id/:version/style.css', (req, res, next) ->
      contentType 'text/css'
      cache {age: '10 minutes', qs: true}, (next) =>
        # todo: build dependency graph to not have double imports
        # or import in the wrong order
        build = (id, version) ->
          root = package_dir id, version
          pkg = read_package id, version
          return [] unless pkg

          pkg.main ?= {css: 'style.styl'}
          css = []

          if pkg.dependencies
            css = css.concat(build(k, v)) for k, v of pkg.dependencies
          if pkg.main.css
            asset = new wrap.Stylus {
              src: path.join root, pkg.main.css
            }
            asset.pkg = pkg
            css.push asset
          css

        css = new wrap.Assets build(req.params.id, req.params.version), {
          compress: useCompression
          vars: req.query
          vars_prefix: '$'
        }, (err) =>
          return error 500, err.toString() if err
          try
            for a in css.assets
              v = ".#{a.pkg.id}.v#{a.pkg.version.replace /\./g, '-'}"
              a.data = a.data.replace /.exports/g, v
            asset = css.merge (err) ->
              next asset.data
          catch err
            error 500, err.stack

    # Public/Static Files
    router.route 'GET', '/pkg/:id/:version/public/*', (req, res, next) ->
      id = req.params.id
      version = req.params.version
      file = req.params[0]
      filepath = path.join "#{package_dir id, version}", 'public', file
      fs.exists filepath, (exists) ->
        if exists
          res.sendfile filepath
        else
          error 404, "File #{file} does not exists"

    # API Calls
    apiCallHandler = (req, res, next) ->
      id = req.params.id
      method = req.params[0]
      version = req.params.version
      svr = require path.join "#{package_dir id, version}", 'api.coffee'
      return error 404 unless svr?[method]
      svr[method].apply {
        body: req.body
        cache: cache
        error: error
        query: req.query
        req: req
        res: res
      }
    router.route 'GET', '/pkg/:id/:version/api/*', apiCallHandler
    router.route 'POST', '/pkg/:id/:version/api/*', apiCallHandler

    # Execute Routes
    router._dispatch req, res, next
