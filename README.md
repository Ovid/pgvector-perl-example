# Using the PgVector PostgreSQL extension in Perl

Perl is a high-level, general-purpose, interpreted, dynamic programming
language. It is widely used in web development, network programming, GUI
development, and more. Perl is known for its powerful text processing features
and is used for many system administration tasks.

However, often we want to search data for the _meaning_ of the data, not just
the text. For example, we might want to search for "dog" and find "puppy" or
"canine" as well. This is where the PgVector extension for PostgreSQL comes in.

# Setup

First, you need to install the PgVector extension. You can find the project
[on github](https://github.com/pgvector/pgvector). You can install the
extension directly, but for the purposes of this example, we will use a Docker
container.

```bash
# Stop and remove existing container (if any)
docker rm -f pgvector-db

# Build fresh image if needed
docker build -t pgvector .

# Run with database creation
docker run -d --name pgvector-db  \
   -e POSTGRES_PASSWORD=mysecretpassword \
   -p 55431:5431 pgvector

# Create database
docker exec -it pgvector-db createdb -U postgres pgvector_perl_test
```

If all does well, you can run the following:

```bash
docker exec -it pgvector-db psql -U postgres -d pgvector_perl_test -c "SELECT 'PostgreSQL available'"
```

That should return `PostgreSQL available`.

Note that the ports and passwords are set to very specific values to allow
this demo to work. In a production environment, you would want to use more
secure/robust settings.

# Using PgVector in Perl

Most of our code is in the `lib` directory. You can use the following simple
script as an example of _semantic_ querying of the data.

This code requires Perl version 5.40.0 or higher. You can install the
dependencies with `cpanm --installdeps .`.

```perl
#!/usr/bin/env perl

use v5.40.0;
use lib 'lib';
use AI::Vector::PgVector;
use DDP;

my $pgvector = AI::Vector::PgVector->new( verbose => 1 );

$pgvector->build_db;
my $results = $pgvector->query( 'books about ghosts', 1.3 );
foreach my $book ( $results->@* ) {
    say $book->to_string;
    say '----';
}
```
