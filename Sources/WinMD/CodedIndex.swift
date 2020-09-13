/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **/

internal protocol CodedIndex: Hashable {
  static var tables: [Table.Type] { get }
}

internal struct HasConstant: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.Param.self,
      Metadata.Tables.Field.self,
      Metadata.Tables.Property.self,
    ]
  }
}

internal struct HasCustomAttribute: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }
}

internal struct CustomAttributeType: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }
}

internal struct HasDeclSecurity: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.Assembly.self,
    ]
  }
}

internal struct TypeDefOrRef: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.TypeRef.self,
      Metadata.Tables.TypeSpec.self,
    ]
  }
}

// FIXME(compnerd) Exported vs Manifest Resource
internal struct Implementation: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.File.self,
      Metadata.Tables.ExportedType.self,
      Metadata.Tables.AssemblyRef.self,
    ]
  }
}

internal struct HasFieldMarshal: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.Field.self,
      Metadata.Tables.Param.self,
    ]
  }
}

internal struct TypeOrMethodDef: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.MethodDef.self,
    ]
  }
}

internal struct MemberForwarded: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.Field.self,
      Metadata.Tables.MethodDef.self,
    ]
  }
}

internal struct MemberRefParent: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.ModuleRef.self,
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.TypeRef.self,
      Metadata.Tables.TypeSpec.self,
    ]
  }
}

internal struct HasSemantics: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.Event.self,
      Metadata.Tables.Property.self,
    ]
  }
}

internal struct MethodDefOrRef: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }
}

internal struct ResolutionScope: CodedIndex {
  public static var tables: [Table.Type] {
    return [
      Metadata.Tables.Module.self,
      Metadata.Tables.ModuleRef.self,
      Metadata.Tables.AssemblyRef.self,
      Metadata.Tables.TypeRef.self,
    ]
  }
}
