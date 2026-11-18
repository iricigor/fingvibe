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
            22 or 23 or 992 or 2222 or 5555 or 5985 or 5986 => "\uE756",
            53 => "\uE968",
            1883 or 8883 => "\uE701",
            2181 or 4222 or 4369 or 5222 or 5269 or 5671 or 5672 or 6667 or 15672 or 61613 or 61616 => "\uE8BD",
            6650 or 9092 => "\uE8AB",
            1433 or 1521 or 3050 or 3306 or 3307 or 5432 or 5433 or 5984 or 6379 or 7474 or 7687 or 8086 or 8529
                or 9042 or 9160 or 11211 or 27017 or 28015 or 9200 or 9300 => "\uEFC7",
            20 or 21 or 115 or 139 or 445 or 548 or 873 or 989 or 990 or 2121 or 5005 or 5006 or 6690 or 6800
                or 6881 or 8384 or 9418 or 22000 or 51413 => "\uE8B7",
            860 or 2049 or 3260 => "\uEDA2",
            3283 or 3389 or 4899 or 5800 or 5900 or 5901 or 5902 or 5903 or 5938 or 6568 => "\uE7F8",
            25 or 109 or 110 or 119 or 143 or 465 or 563 or 587 or 993 or 995 or 2525 or 4190 => "\uE715",
            49 or 88 or 389 or 464 or 636 or 749 or 3268 or 3269 => "\uE8D7",
            443 or 943 or 4443 or 5001 or 5989 or 7443 or 8443 or 8843 or 9443 or 10000 or 10443 or 16993 => "\uE72E",
            80 or 81 or 3000 or 3001 or 4000 or 5000 or 5050 or 5601 or 7080 or 8000 or 8001 or 8006 or 8080
                or 8081 or 8082 or 8083 or 8088 or 8090 or 8112 or 8180 or 8888 or 9000 or 9090 or 9091 => "\uE774",
            502 or 1880 or 4840 or 6053 or 6668 or 8123 or 8581 => "\uEA80",
            554 or 1400 or 1925 or 1935 or 2020 or 2869 or 3483 or 3689 or 5004 or 6466 or 6600 or 7000 or 7100
                or 8002 or 8008 or 8009 or 8060 or 8096 or 8200 or 8554 or 8920 or 10243 or 32400 or 32469
                or 34567 or 37777 => "\uE714",
            111 or 135 or 179 or 593 or 853 or 902 or 1080 or 1194 or 1723 or 2375 or 2376 or 2377 or 2379
                or 3128 or 5335 or 5357 or 5358 or 5988 or 6443 or 6789 or 7547 or 8118 or 8291 or 8728
                or 8729 or 10250 or 16992 => "\uE968",
            515 or 631 or 9100 or 9101 or 9102 => "\uE749",
            4949 or 5666 or 9093 or 10050 or 19999 => "\uE9D9",
            3074 or 3478 or 9295 or 25565 or 27015 or 27036 => "\uE7FC",
            5060 or 5061 => "\uE717",
            62078 => "\uE8EA",
            _ => "\uE9CE"
        },
        _ => "\uE9CE"
    };
}
