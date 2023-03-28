# Single-NIC-DropKick
A rewrite of https://github.com/JulianOliver/dropkick.sh  
The original DropKick relied on having multiple NICs, one to scan in Managed mode and one to craft deauthentication packets in Monitor mode, this script handles both within one NIC by having scanning and deauthentication phases.
