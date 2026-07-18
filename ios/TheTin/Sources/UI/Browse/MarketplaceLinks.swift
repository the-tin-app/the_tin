import Foundation

/// Outbound marketplace URLs for the card-detail links section. Pure string building —
/// URLComponents does the escaping. Plain links today; affiliate params can bolt on later.
enum MarketplaceLinks {
    static func ebayCurrent(name: String, setName: String?, number: String) -> URL {
        ebay(query: query(name: name, setName: setName, number: number), sold: false)
    }

    static func ebaySold(name: String, setName: String?, number: String) -> URL {
        ebay(query: query(name: name, setName: setName, number: number), sold: true)
    }

    /// Product page when the catalog knows the TCGplayer id, else a scoped search.
    static func tcgplayer(tcgplayerId: Int?, name: String, number: String) -> URL {
        if let id = tcgplayerId { return URL(string: "https://www.tcgplayer.com/product/\(id)")! }
        var c = URLComponents(string: "https://www.tcgplayer.com/search/pokemon/product")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(name) \(number)"),
                        URLQueryItem(name: "productLineName", value: "pokemon")]
        return c.url!
    }

    private static func query(name: String, setName: String?, number: String) -> String {
        [name, setName, number].compactMap { $0 }.joined(separator: " ")
    }

    private static func ebay(query: String, sold: Bool) -> URL {
        var c = URLComponents(string: "https://www.ebay.com/sch/i.html")!
        var items = [URLQueryItem(name: "_nkw", value: query)]
        if sold {
            items += [URLQueryItem(name: "LH_Sold", value: "1"),
                      URLQueryItem(name: "LH_Complete", value: "1")]
        }
        c.queryItems = items
        return c.url!
    }
}
