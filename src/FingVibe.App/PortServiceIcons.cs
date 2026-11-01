using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class PortServiceIcons
{
    internal static string Glyph(OpenPort endpoint) => endpoint.Protocol switch
    {
        EndpointProtocol.Udp => endpoint.Port switch
        {
            53 => "\uE968",
            123 => "\uE917",
            _ => "\uE9CE"
        },
        EndpointProtocol.Tcp => endpoint.Port switch
        {
            22 or 23 or 5985 or 5986 => "\uE756",
            53 => "\uE968",
            1883 or 8883 => "\uE701",
            4222 or 4369 or 5671 or 5672 or 15672 or 61613 => "\uE8BD",
            6650 or 9092 => "\uE8AB",
            1433 or 1521 or 3050 or 3306 or 5432 or 6379 or 7474 or 7687 or 8529
                or 9042 or 9160 or 11211 or 27017 or 28015 or 9200 => "\uEFC7",
            20 or 21 or 115 or 139 or 445 or 548 or 873 or 989 or 990 or 8384 => "\uE8B7",
            2049 or 3260 => "\uEDA2",
            3389 or 5800 or 5900 or 5901 or 5902 => "\uE7F8",
            25 or 109 or 110 or 119 or 143 or 465 or 563 or 587 or 993 or 995 or 2525 or 4190 => "\uE715",
            88 or 389 or 464 or 636 or 749 or 3268 or 3269 => "\uE8D7",
            443 or 5001 or 8443 or 9443 or 10000 => "\uE72E",
            80 or 3000 or 3001 or 5000 or 5601 or 8000 or 8001 or 8006 or 8080
                or 8081 or 8088 or 8888 or 9000 or 9090 => "\uE774",
            1880 or 8123 => "\uEA80",
            554 or 3689 or 5004 or 6600 or 7000 or 8008 or 8009 or 8060 or 8096
                or 8200 or 8920 or 32400 => "\uE714",
            111 or 135 or 179 or 593 or 2375 or 2376 or 6443 => "\uE968",
            515 or 631 or 9100 or 9101 => "\uE749",
            _ => "\uE9CE"
        },
        _ => "\uE9CE"
    };
}
