/// Reverse-DNS (or any) host name → service / brand, by domain suffix. Used when a host name is known;
/// the table is deliberately limited to domains whose owner is unambiguous. The most specific suffix
/// wins ("teams.microsoft.com" before "microsoft.com").
public enum HostNameServices {
    /// The service or brand behind `hostName`, or `nil` when no known suffix matches.
    /// Matching is on whole labels: "notgithub.com" does not match "github.com".
    public static func service(forHostName hostName: String) -> String? {
        var name = hostName.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return nil }
        // Try the full name, then drop one leading label at a time.
        var candidate = Substring(name)
        while true {
            if let service = suffixes[String(candidate)] { return service }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    private static let suffixes: [String: String] = {
        var table: [String: String] = [:]
        func add(_ service: String, _ domains: [String]) {
            for domain in domains { table[domain] = service }
        }
        // Google
        add("YouTube", ["googlevideo.com", "youtube.com", "ytimg.com", "youtu.be", "youtube-nocookie.com", "yt.be"])
        add("Google", ["1e100.net", "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com",
                       "gvt1.com", "gvt2.com", "ggpht.com", "google-analytics.com", "googletagmanager.com",
                       "googlesyndication.com", "doubleclick.net", "withgoogle.com", "google.de"])
        add("Google Cloud", ["googlehosted.com", "appspot.com", "run.app", "cloudfunctions.net", "web.app", "firebaseapp.com"])
        add("Google DNS", ["dns.google"])
        add("Gmail", ["gmail.com", "googlemail.com"])
        // Amazon
        add("Amazon CloudFront", ["cloudfront.net"])
        add("Amazon Web Services", ["amazonaws.com", "awsstatic.com", "aws.amazon.com", "awsglobalaccelerator.com", "elasticbeanstalk.com"])
        add("Amazon", ["amazon.com", "amazon.de", "amazon.co.uk", "media-amazon.com", "ssl-images-amazon.com", "amazon-adsystem.com"])
        add("Prime Video", ["primevideo.com", "aiv-cdn.net", "pv-cdn.net"])
        add("Twitch", ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "twitchsvc.net"])
        // CDNs
        add("Akamai", ["akamaitechnologies.com", "akamaiedge.net", "akamai.net", "akamaihd.net", "akamaized.net",
                       "edgekey.net", "edgesuite.net", "akadns.net", "akam.net", "akamai.com"])
        add("Fastly", ["fastly.net", "fastlylb.net", "fastly.com", "fastly-edge.com"])
        add("Cloudflare", ["cloudflare.com", "cloudflare.net", "cloudflare-dns.com", "cloudflarestream.com",
                           "cloudflareinsights.com", "one.one.one.one", "workers.dev", "pages.dev"])
        add("Edgio", ["edgecastcdn.net", "edgio.net", "llnwd.net", "limelight.com"])
        add("Imperva", ["incapdns.net", "imperva.com"])
        // Meta
        add("Meta", ["facebook.com", "fbcdn.net", "fb.com", "facebook.net", "fbsbx.com", "meta.com"])
        add("Instagram", ["instagram.com", "cdninstagram.com"])
        add("WhatsApp", ["whatsapp.net", "whatsapp.com"])
        // Streaming and media
        add("Netflix", ["netflix.com", "nflxvideo.net", "nflximg.net", "nflximg.com", "nflxso.net", "nflxext.com", "netflix.net"])
        add("Spotify", ["spotify.com", "scdn.co", "spotifycdn.com", "spotifycdn.net"])
        add("Discord", ["discord.com", "discordapp.com", "discordapp.net", "discord.gg", "discord.media", "discordstatus.com"])
        add("Steam", ["steampowered.com", "steamcontent.com", "steamstatic.com", "steamserver.net", "steamcommunity.com",
                      "steamusercontent.com", "steamgames.com", "valve.net"])
        add("TikTok", ["tiktok.com", "tiktokcdn.com", "tiktokv.com", "byteoversea.com", "ibytedtos.com", "tiktokcdn-us.com"])
        add("X (Twitter)", ["twitter.com", "twimg.com", "x.com", "t.co"])
        add("LinkedIn", ["linkedin.com", "licdn.com"])
        add("Reddit", ["reddit.com", "redd.it", "redditmedia.com", "redditstatic.com"])
        // Work and developer tools
        add("GitHub", ["github.com", "githubusercontent.com", "githubassets.com", "github.io", "githubapp.com"])
        add("Slack", ["slack.com", "slack-edge.com", "slack-msgs.com", "slack-files.com", "slack-imgs.com", "slack-core.com"])
        add("Zoom", ["zoom.us", "zoom.com", "zoomgov.com"])
        add("Dropbox", ["dropbox.com", "dropboxstatic.com", "dropboxapi.com", "dropboxusercontent.com"])
        add("Docker", ["docker.io", "docker.com"])
        add("npm", ["npmjs.org", "npmjs.com"])
        add("Atlassian", ["atlassian.com", "atlassian.net", "jira.com", "bitbucket.org"])
        add("Adobe", ["adobe.com", "adobe.io", "adobelogin.com", "adobecc.com", "typekit.net"])
        add("Notion", ["notion.so", "notion.site"])
        add("Figma", ["figma.com"])
        add("OpenAI", ["openai.com", "chatgpt.com", "oaiusercontent.com"])
        add("Anthropic", ["anthropic.com", "claude.ai", "claude.com"])
        add("Mozilla", ["mozilla.com", "mozilla.org", "mozilla.net", "firefox.com"])
        add("Wikipedia", ["wikipedia.org", "wikimedia.org"])
        // Apple. Longer suffixes win: push.apple.com is APNs, the rest of apple.com is plain Apple.
        add("Apple", ["apple.com", "mzstatic.com", "apple-dns.net", "apple-cloudkit.com", "cdn-apple.com", "aaplimg.com", "applemusic.com"])
        add("iCloud", ["icloud.com", "icloud-content.com", "me.com"])
        add("Apple Push Notification Service", ["push.apple.com"])
        // Microsoft
        add("Microsoft", ["microsoft.com", "microsoftonline.com", "office.com", "office365.com", "live.com", "outlook.com",
                          "msn.com", "bing.com", "skype.com", "windowsupdate.com", "msedge.net", "msftncsi.com",
                          "microsoftonline-p.com", "sharepoint.com", "onedrive.com", "xboxlive.com", "visualstudio.com"])
        add("Microsoft Teams", ["teams.microsoft.com", "teams.live.com"])
        add("Microsoft Azure", ["windows.net", "azure.com", "azureedge.net", "azurefd.net", "cloudapp.azure.com", "cloudapp.net",
                                "trafficmanager.net", "azurewebsites.net", "azure-api.net", "azure-dns.com", "azure-dns.net"])
        // Hosting providers and networks
        add("DigitalOcean", ["digitalocean.com", "digitaloceanspaces.com", "ondigitalocean.app"])
        add("Hetzner", ["your-server.de", "clients.your-server.de", "hetzner.com", "hetzner.cloud"])
        add("OVHcloud", ["ovh.net", "ovh.com", "ovhcloud.com"])
        add("Linode", ["linode.com", "linodeusercontent.com", "members.linode.com"])
        add("Oracle Cloud", ["oraclecloud.com", "oraclecloudapps.com"])
        add("Alibaba Cloud", ["alibabacloud.com", "aliyuncs.com", "alicdn.com", "aliyun.com"])
        add("Tencent Cloud", ["tencent-cloud.net", "qcloud.com", "myqcloud.com", "tencent.com"])
        add("Vercel", ["vercel.app", "vercel.com", "vercel-dns.com"])
        add("Netlify", ["netlify.app", "netlify.com"])
        add("Fly.io", ["fly.io", "fly.dev"])
        add("Tailscale", ["tailscale.com", "ts.net"])
        add("Deutsche Telekom", ["t-ipconnect.de", "dtag.de", "telekom.de", "t-online.de"])
        add("Vodafone", ["vodafone.de", "kabel-deutschland.de", "vodafone.com"])
        add("Quad9", ["quad9.net"])
        return table
    }()
}

extension DestinationClassifier {
    /// The service or brand behind a host name (reverse DNS or otherwise), by domain suffix:
    /// "rr1---sn-xyz.googlevideo.com" → "YouTube", "ec2-1-2-3-4.compute-1.amazonaws.com" →
    /// "Amazon Web Services". `nil` when no known suffix matches.
    public static func service(forHostName hostName: String) -> String? {
        HostNameServices.service(forHostName: hostName)
    }
}
