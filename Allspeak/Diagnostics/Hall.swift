import Foundation

struct Hall: Identifiable, Equatable, Sendable {
    let key: String
    let name: String

    var id: String { key }

    static let manufakturaCinemaID = "cinema-city-lodz-manufaktura"

    static let manufaktura: [Hall] = [
        Hall(key: "IMAX", name: "IMAX BNP Paribas"),
        Hall(key: "1", name: "Sala 1 Lorenz"),
        Hall(key: "2", name: "Sala 2"),
        Hall(key: "3", name: "Sala 3 Tarczyński"),
        Hall(key: "4", name: "Sala 4 Costa"),
        Hall(key: "5", name: "Sala 5 Credit Agricole"),
        Hall(key: "6", name: "Sala 6 McDonalds"),
        Hall(key: "7", name: "Sala 7 BNP Paribas"),
        Hall(key: "8", name: "Sala 8 4DX Sizeer"),
        Hall(key: "9", name: "Sala 9 Haribo"),
        Hall(key: "10", name: "Sala 10 Familijne"),
        Hall(key: "11", name: "Sala 11 Sizeer"),
        Hall(key: "12", name: "Sala 12 Motorola"),
        Hall(key: "13", name: "Sala 13 T-Mobile"),
        Hall(key: "14", name: "Sala 14 Kinder Bueno"),
    ]
}
