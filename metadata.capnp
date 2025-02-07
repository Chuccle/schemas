@0x94c132d317c55b78;

struct DirectoryEntryMetadata {
    name     @0: Text;
    size     @1: UInt64;
    modified @2: UInt64;
    accessed @3: UInt64;
}

struct DirectoryEntriesMetadata {
    isDir    @0: List(Bool);
    name     @1: List(Text);
    size     @2: List(UInt64);
    modified @3: List(UInt64);
    accessed @4: List(UInt64);
}
