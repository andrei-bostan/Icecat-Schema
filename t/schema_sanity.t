#!perl

use Test::More;
use Test::Deep;
use lib 'lib';
use Icecat::Schema;

unless ( $ENV{RELEASE_TESTING} ) {
    plan( skip_all => "Author tests not required for installation" );
}

eval "use Module::Path";
plan skip_all => "Module::Path required" if $@;

my $schema = Icecat::Schema->connect("ICECAT");

foreach my $source_name ( sort $schema->sources ) {

    next if $source_name =~ /^(ProductWithSellingPrice)$/;

    my $source = $schema->source($source_name);

    my $columns_info = $source->columns_info;

    # check columns

    foreach my $column ( sort keys %$columns_info ) {

        my $data_type = $columns_info->{$column}->{data_type};
        my $size      = $columns_info->{$column}->{size};

        # created/last_modified

        if ( $column =~ /^(created|last_modified)$/ ) {
            ok( defined $columns_info->{$column}->{dynamic_default_on_create},
                "set_on_create exists for $source_name $column" );

            if ( $column eq 'last_modified' ) {
                ok(
                    defined $columns_info->{$column}
                      ->{dynamic_default_on_update},
                    "set_on_update exists for $source_name $column"
                );
            }
        }

        # auto_increment

        if ( $columns_info->{$column}->{is_auto_increment} ) {
            ok(
                defined $data_type && $data_type eq 'integer',
                "$source_name $column has integer auto_increment col"
            );
        }

        # data_type specific checks

        if ( $data_type =~
            /^(enum|(medium|small|tiny)*int(eger)*|(medium)*text)$/ )
        {

            # nothing to see
        }
        elsif ( $data_type eq 'boolean' ) {
            my $default_value = $columns_info->{$column}->{default_value};
            if ( defined $default_value ) {
                fail "$source_name $column "
                  . "default_value for boolean should be 0 or 1"
                  unless $default_value =~ /^[01]$/;
            }
        }
        elsif ( $data_type =~ /^(var)*char$/ ) {
            ok( defined $size, "size is defined for $source_name $column" )
              && cmp_ok( $size, '>=', 1, "size >= 1 for $source_name $column" );
        }
        elsif ( $data_type eq 'numeric' ) {
                 ok( defined $size, "size is defined for $source_name $column" )
              && ok( ref($size) eq 'ARRAY', "and is an array" )
              && cmp_ok( scalar @$size, '==', 2, "that has 2 elements" )
              && cmp_ok( $size->[0], '>=', $size->[1],
                "and precision >= scale" );
        }
        elsif ( $data_type =~ /^(date(time)*|timestamp)$/ ) {
            ok(
                defined $columns_info->{$column}->{_ic_dt_method},
                "InflateColumn::DateTime set for $source_name $column"
            );
        }
        else {
            fail("unexpected data_type $data_type for $source_name $column");
        }

        # POD comparison

        # we need a mangled form of columns_info to cope with magic
        # stuff handled by components

        my $info = $columns_info->{$column};
        delete $info->{_ic_dt_method};
        delete $info->{_inflate_info};

        if ( $info->{dynamic_default_on_create} ) {
            delete $info->{dynamic_default_on_create};
            $info->{set_on_create} = 1;
        }

        if ( $info->{dynamic_default_on_update} ) {
            delete $info->{dynamic_default_on_update};
            $info->{set_on_update} = 1;
        }

    }

    # check relationships

    my @source_relations = $source->relationships;

    foreach my $relname (@source_relations) {

        cmp_ok( $relname, 'eq', lc($relname),
            "relname $relname is lc in $source_name" );

        my $relationship = $source->relationship_info($relname);
        my $reverse      = $source->reverse_relationship_info($relname);

        ( my $foreign_source_name = $relationship->{source} ) =~ s/.*://;

        # check columns exist in self and foreign then check data_type and size

        my $foreign_source       = $schema->source($foreign_source_name);
        my $foreign_columns_info = $foreign_source->columns_info;

        # skip complex rels
        next if ref( $relationship->{cond} ) eq 'CODE';

        if (
            !(
                (
                    $relationship->{class} eq
                    'Icecat::Schema::Result::Vocabulary' && eq_deeply(
                        $relationship->{cond}, { 'foreign.sid' => 'self.sid' }
                    )
                )
                || (
                    $relationship->{class} eq 'Icecat::Schema::Result::Tex'
                    && eq_deeply(
                        $relationship->{cond}, { 'foreign.tid' => 'self.tid' }
                    )
                )
                || (
                    $relationship->{class} eq 'Icecat::Schema::Result::Language'
                    && eq_deeply(
                        $relationship->{cond},
                        { 'foreign.langid' => 'self.backup_langid' }
                    )
                )
            )
          )

        {
            ok %$reverse, "reverse relationship for $source_name -> $relname"
              or diag explain $relationship;
        }

        my @cond = %{ $relationship->{cond} };

        my ($self_column)    = grep { s/^self\.// } @cond;
        my ($foreign_column) = grep { s/^foreign\.// } @cond;

        ok(
            $columns_info->{$self_column},
            "$source_name has column $self_column"
          )

          && ok( $foreign_columns_info->{$foreign_column},
                "foreign column $foreign_column exists for relation "
              . "$source_name -> $relname" )

          && cmp_ok(
            $columns_info->{$self_column}->{data_type},
            'eq',
            $foreign_columns_info->{$foreign_column}->{data_type},
            "data_type matches across relationship $relname in $source_name"
          )

          && ( $columns_info->{$self_column}->{data_type} =~ /^(var)*char$/ )

          && cmp_ok(
            $columns_info->{$self_column}->{size},
            'eq',
            $foreign_columns_info->{$foreign_column}->{size},
            "size matches across relationship $relname in $source_name"
          );

        if (   $columns_info->{$self_column}->{is_foreign_key}
            && $columns_info->{$self_column}->{is_nullable} )
        {
            like( $relationship->{attrs}->{join_type},
                qr/^left$/i,
                "nullable FK has join type LEFT for $relname in $source_name" );
        }
    }
}

done_testing;
