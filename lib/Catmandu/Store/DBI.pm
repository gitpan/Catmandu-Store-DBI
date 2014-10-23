package Catmandu::Store::DBI;

use namespace::clean;
use Catmandu::Sane;
use DBI;
use Moo;

our $VERSION = "0.03";

with 'Catmandu::Store';

has data_source => (
    is       => 'ro',
    required => 1,
    trigger  => sub { $_[0] =~ /^DBI:/i ? $_[0] : "DBI:$_[0]" },
);

has username => ( is => 'ro', default => sub { '' } );
has password => ( is => 'ro', default => sub { '' } );

has dbh => (
    is       => 'ro',
    init_arg => undef,
    lazy     => 1,
    builder  => '_build_dbh',
);

# Only mysql seems to need auto_reconnect for now
sub _build_dbh {
    my $self = $_[0];
    my $opts = {
        AutoCommit           => 1,
        RaiseError           => 1,
        mysql_auto_reconnect => 1,
    };
    DBI->connect($self->data_source, $self->username, $self->password, $opts);
}

sub transaction {
    my ($self, $sub) = @_;

    if ($self->{_tx}) {
        return $sub->();
    }

    my $dbh = $self->dbh;
    my @res;

    eval {
        $self->{_tx} = 1;
        $dbh->begin_work;
        @res = $sub->();
        $dbh->commit;
        $self->{_tx} = 0;
        1;
    } or do {
        my $err = $@;
        eval { $dbh->rollback };
        $self->{_tx} = 0;
        die $err;
    };

    @res;
}

sub DEMOLISH {
    $_[0]->dbh->disconnect if $_[0]->dbh;
}

package Catmandu::Store::DBI::Bag;

use Catmandu::Sane;
use Moo;
use Catmandu::Iterator;

with 'Catmandu::Bag';
with 'Catmandu::Serializer';

has _sql_get    => (is => 'ro', lazy => 1, builder => '_build_sql_get');
has _sql_delete => (is => 'ro', lazy => 1, builder => '_build_sql_delete');
has _sql_delete_all =>
  (is => 'ro', lazy => 1, builder => '_build_sql_delete_all');
has _sql_generator =>
  (is => 'ro', lazy => 1, builder => '_build_sql_generator');
has _sql_count => (is => 'ro', lazy => 1, builder => '_build_sql_count');
has _add       => (is => 'ro', lazy => 1, builder => '_build_add');

sub BUILD {
    $_[0]->_build_create;
}

sub _build_sql_get {
    my $name = $_[0]->name;
    "select data from $name where id=?";
}

sub _build_sql_delete {
    my $name = $_[0]->name;
    "delete from $name where id=?";
}

sub _build_sql_delete_all {
    my $name = $_[0]->name;
    "delete from $name";
}

sub _build_sql_generator {
    my $name = $_[0]->name;
    "select data from $name";
}

sub _build_sql_count {
    my $name = $_[0]->name;
    "select count(*) from $name";
}

sub _build_add_sqlite {
    my $self = $_[0];
    my $name = $self->name;
    my $sql  = "insert or replace into $name(id,data) values(?,?)";
    sub {
        my $dbh = $self->store->dbh;
        my $sth = $dbh->prepare_cached($sql)
          or Catmandu::Error->throw($dbh->errstr);
        $sth->execute($_[0], $_[1]) or Catmandu::Error->throw($sth->errstr);
        $sth->finish;
    };
}

sub _build_add_mysql {
    my $self = $_[0];
    my $name = $self->name;
    my $sql = "insert into $name(id,data) values(?,?) on duplicate key update data=values(data)";
    sub {
        my $dbh = $self->store->dbh;
        my $sth = $dbh->prepare_cached($sql)
            or Catmandu::Error->throw($dbh->errstr);
        $sth->execute($_[0], $_[1])
            or Catmandu::Error->throw($sth->errstr);
        $sth->finish;
    };
}

sub _build_add_postgres {
    # See http://stackoverflow.com/questions/15840922/where-not-exists-in-postgresql-gives-syntax-error
    my $self       = $_[0];
    my $name       = $self->name;
    my $sql_update = "update $name set data=? where id=?";
    my $sql_insert = "insert into $name select ?,? where not exists (select 1 from $name where id=?)";
    sub {
        my $dbh = $self->store->dbh;
        my $sth = $dbh->prepare_cached($sql_update)
            or Catmandu::Error->throw($dbh->errstr);
        $sth->execute($_[1], $_[0])
            or Catmandu::Error->throw($sth->errstr);
        unless ($sth->rows) {
            $sth->finish;
            $sth = $dbh->prepare_cached($sql_insert)
              or Catmandu::Error->throw($dbh->errstr);
            $sth->execute( $_[0], $_[1], $_[0] )
              or Catmandu::Error->throw($sth->errstr);
            $sth->finish;
        }
    };
}

sub _build_add_generic {
    my $self       = $_[0];
    my $name       = $self->name;
    my $sql_update = "update $name set data=? where id=?";
    my $sql_insert = "insert into $name values(?,?) where not exists (select 1 from $name where id=?)";
    sub {
        my $dbh = $self->store->dbh;
        my $sth = $dbh->prepare_cached($sql_update)
          or Catmandu::Error->throw( $dbh->errstr );
        $sth->execute($_[1], $_[0]) or Catmandu::Error->throw($sth->errstr);
        unless ($sth->rows) {
            $sth->finish;
            $sth = $dbh->prepare_cached($sql_insert)
              or Catmandu::Error->throw($dbh->errstr);
            $sth->execute( $_[0], $_[1], $_[0] )
              or Catmandu::Error->throw($sth->errstr);
            $sth->finish;
        }
    };
}

sub _build_create {
    my $self = $_[0];
    my $driver_name = $self->store->dbh->{Driver}{Name} // "";
    if ($driver_name =~ /pg/i) { return $self->_build_create_postgres }
    $self->_build_create_generic;
}

sub _build_create_postgres {
    my $self = $_[0];
    my $name = $self->name;
    my $dbh  = $self->store->dbh;
    # requires al least Postgres 9.1
    # TODO get rid of this annoying warning:
    # 'NOTICE:  relation "$name" already exists, skipping'
    my $sql = "create table if not exists $name(id varchar(255) not null primary key, data bytea not null)";
    $dbh->do($sql) or Catmandu::Error->throw($dbh->errstr);
}

sub _build_create_generic {
    my $self = $_[0];
    my $name = $self->name;
    my $dbh  = $self->store->dbh;
    my $sql = "create table if not exists $name(id varchar(255) not null primary key, data longblob not null)";
    $dbh->do($sql) or Catmandu::Error->throw($dbh->errstr);
}

sub _build_add {
    my $self = $_[0];
    my $driver_name = $self->store->dbh->{Driver}{Name} // "";
    if ($driver_name =~ /sqlite/i) { return $self->_build_add_sqlite; }
    if ($driver_name =~ /mysql/i)  { return $self->_build_add_mysql; }
    if ($driver_name =~ /pg/i)     { return $self->_build_add_postgres; }
    return $self->_build_add_generic;
}

sub get {
    my ($self, $id) = @_;
    my $dbh = $self->store->dbh;
    my $sth = $dbh->prepare_cached($self->_sql_get)
        or Catmandu::Error->throw($dbh->errstr);
    $sth->execute($id) or Catmandu::Error->throw($sth->errstr);
    my $data;
    if (my $row = $sth->fetchrow_arrayref) {
        $data = $self->deserialize($row->[0]);
    }
    $sth->finish;
    $data;
}

sub add {
    my ($self, $data) = @_;
    $self->_add->($data->{_id}, $self->serialize($data));
}

sub delete_all {
    my ($self) = @_;
    my $dbh    = $self->store->dbh;
    my $sth    = $dbh->prepare_cached($self->_sql_delete_all)
        or Catmandu::Error->throw($dbh->errstr);
    $sth->execute or Catmandu::Error->throw($sth->errstr);
    $sth->finish;
}

sub delete {
    my ($self, $id) = @_;
    my $dbh = $self->store->dbh;
    my $sth = $dbh->prepare_cached($self->_sql_delete)
      or Catmandu::Error->throw($dbh->errstr);
    $sth->execute($id) or Catmandu::Error->throw($sth->errstr);
    $sth->finish;
}

sub generator {
    my ($self) = @_;
    my $dbh = $self->store->dbh;
    sub {
        state $sth;
        state $row;
        unless ($sth) {
            $sth = $dbh->prepare($self->_sql_generator)
                or Catmandu::Error->throw($dbh->errstr);
            $sth->execute;
        }
        if ( $row = $sth->fetchrow_arrayref ) {
            return $self->deserialize($row->[0]);
        }
        $sth->finish;
        return;
    };
}

sub count {
    my ($self) = @_;
    my $dbh    = $self->store->dbh;
    my $sth    = $dbh->prepare_cached($self->_sql_count)
      or Catmandu::Error->throw($dbh->errstr);
    $sth->execute or Catmandu::Error->throw($sth->errstr);
    my ($n) = $sth->fetchrow_array;
    $sth->finish;
    $n;
}

# mysql:     select * from <bag> limit <offset>,<limit>
# postgres:  select * from <bag> limit <limit> offset <offset>
# sqlite:    select * from <bag> limit <offset>,<limit>
#            select * from <bag> limit <limit> offset <offset>

has _sql_slice => (is => 'ro', lazy => 1, builder => '_build_sql_slice');

sub _build_sql_slice {
    my $self = $_[0];
    my $driver_name = $self->store->dbh->{Driver}{Name} // "";
    if ($driver_name =~ /sqlite/i) { return $self->_build_slice_sqlite; }
    if ($driver_name =~ /mysql/i)  { return $self->_build_slice_mysql; }
    if ($driver_name =~ /pg/i)     { return $self->_build_slice_postgres; }
    # TODO fall back on default slice implementation
    Catmandu::NotImplemented->throw("slice is only supported for mysql, postgres or sqlite");
}

sub _build_slice_sqlite {
    my $self = $_[0];
    my $name = $self->name;
    my $dbh  = $self->store->dbh;
    my $sql  = "SELECT data FROM $name LIMIT ?,?";

    sub {
        my ($start, $limit) = @_;
        my $sth = $dbh->prepare_cached($sql)
          or Catmandu::Error->throw($dbh->errstr);
        $sth->execute( $start, $limit )
          or Catmandu::Error->throw($sth->errstr);
        $sth;
    };
}

sub _build_slice_mysql {
    my $self = $_[0];
    my $name = $self->name;
    my $dbh  = $self->store->dbh;
    my $sql  = "SELECT data FROM $name LIMIT ?,?";

    sub {
        my ($start, $limit) = @_;
        my $sth = $dbh->prepare_cached($sql)
          or Catmandu::Error->throw($dbh->errstr);
        $sth->execute( $start, $limit )
          or Catmandu::Error->throw($sth->errstr);
        $sth;
    };
}

sub _build_slice_postgres {
    my $self = $_[0];
    my $name = $self->name;
    my $dbh  = $self->store->dbh;
    my $sql  = "SELECT data FROM $name LIMIT ? OFFSET ?";

    sub {
        my ($start, $limit) = @_;
        my $sth = $dbh->prepare_cached($sql)
          or Catmandu::Error->throw($dbh->errstr);
        $sth->execute($limit, $start)
          or Catmandu::Error->throw($sth->errstr);
        $sth;
    };
}

sub slice {
    my ($self, $start, $total) = @_;
    $start //= 0;
    my $dbh = $self->store->dbh;

    Catmandu::Iterator->new(
        sub {
            sub {
                if (defined $total) {
                    $total || return;
                }

                state $sth;
                state $row;
                unless ($sth) {
                    if (defined($total)) {
                        $sth = $self->_sql_slice->($start, $total);
                    }
                    else {
                        $sth = $dbh->prepare($self->_sql_generator)
                          or Catmandu::Error->throw($dbh->errstr);
                        $sth->execute;
                    }
                }
                if ($row = $sth->fetchrow_arrayref) {
                    return $self->deserialize($row->[0]);
                }
                $sth->finish;
                return;

              }
        }
    );

}

1;

=head1 NAME

Catmandu::Store::DBI - A Catmandu::Store plugin for DBI based interfaces

=head1 VERSION

Version 0.02

=head1 SYNOPSIS

    use Catmandu::Store::DBI;

    my $store = Catmandu::Store::DBI->new(
        data_source => 'DBI:mysql:database=test', # prefix "DBI:" optionl
        username => '', # optional
        password => '', # optional
    );

    my $obj1 = $store->bag->add({ name => 'Patrick' });

    printf "obj1 stored as %s\n" , $obj1->{_id};

    # Force an id in the store
    my $obj2 = $store->bag->add({ _id => 'test123' , name => 'Nicolas' });

    my $obj3 = $store->bag->get('test123');

    $store->bag->delete('test123');

    $store->bag->delete_all;

    # All bags are iterators
    $store->bag->each(sub { ... });
    $store->bag->take(10)->each(sub { ... });

The L<catmandu> command line client can be used like this:

    catmandu import JSON to DBI --data_source SQLite:mydb.sqlite < data.json
    
=head1 DESCRIPTION

A Catmandu::Store::DBI is a Perl package that can store data into
DBI backed databases. The database as a whole is called a 'store'
(L<Catmandu::Store>. Databases also have compartments (e.g. tables) 
called 'bags' (L<Catmandu::Bag>).

=head1 METHODS

=head2 new(data_source => $data_source)

Create a new Catmandu::Store::DBI store using a DBI $data_source. The 
prefix "DBI:" is added automatically if needed.

=head2 bag($name)

Create or retieve a bag with name $name. Returns a Catmandu::Bag.

=head1 AUTHOR

Nicolas Steenlant, C<< <nicolas.steenlant at ugent.be> >>

=head1 CONTRIBUTOR

Vitali Peil C<< <vitali.peil at uni-bielefeld.de> >>

=head1 CONTRIBUTOR

Nicolas Franck C<< <nicolas.franck at ugent.be> >>

=head1 SEE ALSO

L<Catmandu::Bag>, L<Catmandu::Searchable>, L<DBI>

=cut
