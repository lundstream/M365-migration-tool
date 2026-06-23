@{
    # Pode server configuration. Loaded via Start-PodeServer -RootPath (this folder).
    Server = @{
        Request = @{
            # Mutating operations (e.g. creating many MailUsers, connecting EXO/SPO) can run
            # well past Pode's 30s default and would otherwise return HTTP 408. 10 minutes.
            Timeout  = 600
            BodySize = 104857600
        }
    }
}
