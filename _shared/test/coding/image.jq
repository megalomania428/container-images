.[0].Config
| (.User // "" | split(":")[0] // "") as $user
| ($user == "" or $user == "0" or $user == "root")
  and ((.Volumes // {}) | has("/srv/data/podman/coder"))
  and ((.Volumes // {}) | has("/home/coder"))
  and ((.Volumes // {}) | has("/var/lib/host-identity"))
