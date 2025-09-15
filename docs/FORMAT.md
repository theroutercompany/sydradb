# On-Disk Format v0 (Draft)

## WAL
- Record: [len:u32][type:u8][payload][crc:u32]
- Types: PUT, DELETE, META

## TS-SST
- Column pages: ts[], value[], tags_bitmap
- Index blocks per series; footer with offsets; magic 'SYDRA0'
